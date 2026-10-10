//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import SystemPackage
import TerminalProgress

/// The engine compose talks to when it is not a test: the API server, through the same
/// clients the `container` commands use.
public struct LiveComposeEngine: ComposeEngine {
    /// Bookmarks for the host folders a container mounts, from an embedder that holds
    /// grants for them. A command line has none, and the engine asks for what it needs.
    public var hostDirectoryBookmarks: @Sendable ([String]) -> [Data]
    /// The scheme to reach an image's registry with: `https`, `http` or `auto`.
    public var registryScheme: @Sendable (_ image: String) -> String
    let log: Logger

    public init(
        log: Logger = Logger(label: "com.apple.container.compose"),
        hostDirectoryBookmarks: @escaping @Sendable ([String]) -> [Data] = { _ in [] },
        registryScheme: @escaping @Sendable (String) -> String = { _ in "https" }
    ) {
        self.log = log
        self.hostDirectoryBookmarks = hostDirectoryBookmarks
        self.registryScheme = registryScheme
    }

    /// The engine's configuration, from the roots the running engine reports.
    private func systemConfig() async throws -> ContainerSystemConfig {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
        let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
        return try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
            ])
    }

    // MARK: Containers

    private static func container(_ snapshot: ContainerSnapshot) -> ComposeContainer {
        let state: ComposeContainer.State
        switch snapshot.status {
        case .running: state = .running
        case .stopped: state = .stopped
        case .restarting: state = .restarting
        case .unknown, .stopping: state = .changing
        }
        let ports = snapshot.configuration.publishedPorts.map { port -> String in
            let range = { (start: UInt16) in port.count > 1 ? "\(start)-\(start + port.count - 1)" : "\(start)" }
            return "\(range(port.hostPort)):\(range(port.containerPort))/\(port.proto.rawValue)"
        }
        return ComposeContainer(
            id: snapshot.id,
            image: snapshot.configuration.image.reference,
            imageDigest: snapshot.configuration.image.digest,
            state: state,
            exitCode: snapshot.exitCode,
            labels: snapshot.configuration.labels,
            ports: ports,
            startedAt: snapshot.startedDate)
    }

    public func containers(project: String) async throws -> [ComposeContainer] {
        // A label filter's value is a pattern; a project name has nothing in it that a
        // pattern reads as anything but itself, and the anchors keep `shop` from
        // matching `shop2`.
        let filters = ContainerListFilters(labels: [ComposeLabels.project: "^\(NSRegularExpression.escapedPattern(for: project))$"])
        return try await ContainerClient().list(filters: filters).map(Self.container)
    }

    public func container(named name: String) async throws -> ComposeContainer? {
        do {
            return Self.container(try await ContainerClient().get(id: name))
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return nil
        }
    }

    public func createContainer(_ request: ContainerRequest, progress: @escaping ProgressUpdateHandler) async throws {
        // The command line is read by the options `container run` has, which is what makes
        // a service the container the same line typed at a prompt would be.
        let options: RunOptions
        do {
            options = try RunOptions.parse(request.arguments)
        } catch {
            throw ComposeError("the container \(request.name) cannot be made: \(RunOptions.message(for: error))")
        }
        var (configuration, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: Utility.createContainerID(name: options.management.name),
            image: options.image,
            arguments: options.arguments,
            process: options.process,
            management: options.management,
            resource: options.resource,
            registry: Flags.Registry(scheme: registryScheme(options.image)),
            imageFetch: options.imageFetch,
            containerSystemConfig: try await systemConfig(),
            progressUpdate: progress,
            log: log)
        if let stopSignal = request.stopSignal { configuration.stopSignal = stopSignal }
        try await ContainerClient().create(
            configuration: configuration,
            options: ContainerCreateOptions(autoRemove: false),
            kernel: kernel,
            initImage: initImage,
            hostDirectoryBookmarks: hostDirectoryBookmarks(Self.boundFolders(of: configuration)))
    }

    private static func boundFolders(of configuration: ContainerConfiguration) -> [String] {
        var seen = Set<String>()
        return configuration.mounts.filter(\.isVirtiofs).map(\.source).filter { seen.insert($0).inserted }
    }

    public func startContainer(_ id: String) async throws {
        let client = ContainerClient()
        let snapshot = try await client.get(id: id)
        guard snapshot.status != .running, snapshot.status != .restarting else { return }
        do {
            let io = try ProcessIO.create(tty: snapshot.configuration.initProcess.terminal, interactive: false, detach: true)
            defer { try? io.close() }
            let process = try await client.bootstrap(
                id: id, stdio: io.stdio, hostDirectoryBookmarks: hostDirectoryBookmarks(Self.boundFolders(of: snapshot.configuration)))
            try await process.start()
            try io.closeAfterStart()
        } catch {
            // What a failed start leaves half-made would get in the way of the next one.
            try? await client.stop(id: id)
            throw error
        }
    }

    public func stopContainer(_ id: String, timeout: Int?) async throws {
        var options = ContainerStopOptions.default
        if let timeout { options.timeoutInSeconds = Int32(clamping: timeout) }
        try await ContainerClient().stop(id: id, opts: options)
    }

    public func removeContainer(_ id: String) async throws {
        do {
            try await ContainerClient().delete(id: id, force: true)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            // Already gone, which is what was asked for.
        }
    }

    public func run(_ command: [String], in id: String, timeout: Double) async throws -> Int32? {
        guard let executable = command.first else { return 0 }
        let client = ContainerClient()
        // The check runs as the container's own process would: same environment, same
        // user, same working directory.
        var configuration = try await client.get(id: id).configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(command.dropFirst())
        configuration.terminal = false
        let process = try await client.createProcess(
            containerId: id, processId: UUID().uuidString.lowercased(), configuration: configuration, stdio: [nil, nil, nil])
        try await process.start()
        return try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask { try await process.wait() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let exitCode = first else {
                try? await process.kill(SIGKILL)
                return nil
            }
            return exitCode
        }
    }

    // MARK: Networks

    public func networkExists(_ name: String) async throws -> Bool {
        do {
            _ = try await NetworkClient().get(id: name)
            return true
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return false
        }
    }

    public func createNetwork(_ network: NetworkPlan) async throws {
        let configuration = try NetworkConfiguration(
            name: network.name,
            mode: network.isInternal ? .hostOnly : .nat,
            ipv4Subnet: try network.subnet.map { try CIDRv4($0) },
            labels: try ResourceLabels(network.labels),
            plugin: "container-network-vmnet")
        _ = try await NetworkClient().create(configuration: configuration)
    }

    public func removeNetwork(_ name: String) async throws {
        do {
            try await NetworkClient().delete(id: name)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            // Already gone.
        }
    }

    public func networks(project: String) async throws -> [String] {
        try await NetworkClient().list()
            .filter { $0.configuration.labels.dictionary[ComposeLabels.project] == project }
            .map(\.id)
    }

    // MARK: Volumes

    public func volumeExists(_ name: String) async throws -> Bool {
        try await ClientVolume.list().contains { $0.name == name }
    }

    public func createVolume(_ volume: VolumePlan) async throws {
        _ = try await ClientVolume.create(name: volume.name, driver: "local", driverOpts: [:], labels: volume.labels)
    }

    public func removeVolume(_ name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    public func volumes(project: String) async throws -> [String] {
        try await ClientVolume.list().filter { $0.labels[ComposeLabels.project] == project }.map(\.name)
    }

    // MARK: Images

    public func imageDigest(_ reference: String) async throws -> String? {
        do {
            return try await ClientImage.get(reference: reference, containerSystemConfig: try await systemConfig()).description.digest
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return nil
        }
    }

    public func pullImage(_ reference: String, platform: String?, progress: @escaping ProgressUpdateHandler) async throws -> String {
        let image = try await ClientImage.pull(
            reference: reference,
            platform: try platform.map { try Platform(from: $0) },
            scheme: try RequestScheme(registryScheme(reference)),
            containerSystemConfig: try await systemConfig(),
            progressUpdate: progress)
        return image.description.digest
    }

    // MARK: Ports

    public func freeHostPort() async throws -> Int {
        // A port a stopped container publishes is free now and taken when it starts.
        let reserved = Set(
            try await ContainerClient().list().flatMap { snapshot in
                snapshot.configuration.publishedPorts.flatMap { port in
                    (0..<Int(port.count)).map { Int(port.hostPort) + $0 }
                }
            })
        for _ in 0..<64 {
            let port = try Self.unusedPort()
            if !reserved.contains(port) { return port }
        }
        throw ComposeError("no free host port was found for a port published without one")
    }

    /// A port the system hands out when asked for any: bound for a moment and let go.
    private static func unusedPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ComposeError("could not open a socket to find a free host port") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, length) == 0 && Darwin.getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else { throw ComposeError("could not bind a socket to find a free host port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
