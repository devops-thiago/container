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
import ContainerizationOCI
import ContainerizationOS
import Darwin
import DockerAPIService
import Foundation
import SystemPackage

/// The container routes' engine: the API server and the images service, through the clients
/// the `container` commands use. A create does what `container create` does once its image is
/// here: unpack the image, find the kernel, fetch and unpack the init image, create. It never
/// pulls the image itself; a missing one is the client's to pull.
struct EngineContainersClient: EngineContainers {
    /// The engine's configuration, from the roots the running engine reports.
    static func systemConfig() async throws -> ContainerSystemConfig {
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let appRoot = FilePath(health.appRoot.path(percentEncoded: false))
        let installRoot = FilePath(health.installRoot.path(percentEncoded: false))
        return try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: appRoot, of: .appRoot),
                ConfigurationLoader.configurationFile(in: installRoot, of: .installRoot),
            ])
    }

    func list() async throws -> [ContainerSnapshot] {
        try await Self.translated { try await ContainerClient().list(filters: ContainerListFilters.all.withoutInfrastructure()) }
    }

    func builtinNetwork() async throws -> String? {
        try await NetworkClient().builtin?.id
    }

    func image(_ reference: String, platform requested: String?) async throws -> DockerImageDefaults? {
        let system = try await Self.systemConfig()
        let platform: ContainerizationOCI.Platform
        do {
            platform = try requested.map(Parser.platform(from:)) ?? Parser.platform(os: "linux", arch: Arch.hostArchitecture().rawValue)
        } catch {
            throw DockerAPIError.badRequest("invalid platform \(requested ?? ""): \(error)")
        }
        do {
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: system)
            let manifest = try await image.manifest(for: platform)
            let config = try await image.config(for: platform).config
            return DockerImageDefaults(
                description: image.description,
                id: manifest.config.digest,
                platform: platform,
                user: config?.user,
                env: config?.env,
                entrypoint: config?.entrypoint,
                cmd: config?.cmd,
                workingDir: config?.workingDir,
                labels: config?.labels,
                stopSignal: config?.stopSignal,
                healthCheck: try await image.healthCheck(for: platform))
        } catch let error as ContainerizationError where error.isCode(.notFound) || error.isCode(.unsupported) {
            // Not here, or not for this platform (its manifest not pulled, or not in its index):
            // either way the client pulls it, and a pull that cannot succeed says why.
            return nil
        }
    }

    func createDefaults() async throws -> DockerCreateDefaults {
        let system = try await Self.systemConfig()
        let resources = try Parser.resources(cpus: nil, memory: nil, defaultCPUs: system.container.cpus, defaultMemory: system.container.memory)
        return DockerCreateDefaults(
            cpus: resources.cpus, memoryInBytes: resources.memoryInBytes, dnsDomain: system.dns.domain, builtinNetwork: try await builtinNetwork(),
            hostArchitecture: Platform.current.architecture)
    }

    func allocatePort() throws -> UInt16 {
        if let port = Self.unusedPort() { return port }
        // A socket of its own may be refused to a sandboxed agent; a port from the ephemeral
        // range then stands in, which the engine refuses at start if something holds it.
        return UInt16.random(in: 49152...65535)
    }

    /// A port the system hands out when asked for any: bound for a moment and let go.
    private static func unusedPort() -> UInt16? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
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
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }

    func create(_ plan: DockerCreatePlan, requester: String?) async throws -> String {
        try await Self.translated {
            var configuration = plan.configuration
            for volume in plan.volumes {
                let found = try await Self.volume(volume)
                configuration.mounts.append(
                    .volume(
                        name: volume.name, format: found.format, source: found.source, destination: volume.destination,
                        options: volume.readOnly ? ["ro"] : []))
            }
            let system = try await Self.systemConfig()
            _ = try await ClientImage(description: configuration.image).getCreateSnapshot(platform: configuration.platform)
            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            let initImage = try await ClientImage.fetch(reference: system.vminit.image, platform: .current, containerSystemConfig: system)
            _ = try await initImage.getCreateSnapshot(platform: .current)
            return try await ContainerClient().create(
                configuration: configuration, options: ContainerCreateOptions(autoRemove: plan.autoRemove), kernel: kernel,
                requester: requester)
        }
    }

    /// The named volume a mount asks for, made when it does not exist, as dockerd makes one.
    private static func volume(_ request: DockerVolumeRequest) async throws -> VolumeConfiguration {
        do {
            return try await ClientVolume.create(
                name: request.name, driver: "local", labels: request.anonymous ? [VolumeConfiguration.anonymousLabel: ""] : [:])
        } catch let error as VolumeError {
            guard case .volumeAlreadyExists = error else { throw error }
            return try await ClientVolume.inspect(request.name)
        } catch let error as ContainerizationError where error.message.contains("already exists") {
            return try await ClientVolume.inspect(request.name)
        }
    }

    func bootstrap(_ container: ContainerSnapshot, stdio: DockerProcessStdio, requester: String?) async throws -> any EngineProcess {
        try await Self.translated {
            let client = ContainerClient()
            do {
                return EngineProcessClient(process: try await client.bootstrap(id: container.id, stdio: stdio.handles, requester: requester))
            } catch {
                // What a failed bootstrap leaves half-made would get in the way of the next one.
                try? await client.stop(id: container.id, expectedIncarnation: Self.incarnation(container))
                throw error
            }
        }
    }

    func get(_ engineID: String) async throws -> ContainerSnapshot? {
        do {
            return try await ContainerClient().get(id: engineID)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return nil
        }
    }

    func stop(_ container: ContainerSnapshot, timeout: Int32, signal: String?) async throws {
        try await Self.translated {
            try await ContainerClient().stop(
                id: container.id, opts: ContainerStopOptions(timeoutInSeconds: timeout, signal: signal), expectedIncarnation: Self.incarnation(container))
        }
    }

    func kill(_ container: ContainerSnapshot, signal: String) async throws {
        try await Self.translated { try await ContainerClient().kill(id: container.id, signal: signal) }
    }

    func delete(_ container: ContainerSnapshot, force: Bool) async throws {
        try await Self.translated {
            try await ContainerClient().delete(id: container.id, force: force, expectedIncarnation: Self.incarnation(container))
        }
    }

    func deleteVolume(_ name: String) async throws {
        try await Self.translated { try await ClientVolume.delete(name: name) }
    }

    private static func incarnation(_ container: ContainerSnapshot) -> String? {
        container.incarnation.isEmpty ? nil : container.incarnation
    }

    /// The engine's errors in the HTTP status a Docker client acts on.
    private static func translated<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ContainerizationError {
            switch error.code {
            case .notFound: throw DockerAPIError.notFound(error.message)
            case .exists, .invalidState: throw DockerAPIError.conflict(error.message)
            case .invalidArgument, .unsupported: throw DockerAPIError.badRequest(error.message)
            default: throw error
            }
        }
    }
}

/// A process the API server bootstrapped, through the client the `container` commands use.
struct EngineProcessClient: EngineProcess {
    let process: any ClientProcess

    func start() async throws {
        try await process.start()
    }

    func wait() async throws -> Int32 {
        try await process.wait()
    }

    func resize(width: UInt16, height: UInt16) async throws {
        try await process.resize(Terminal.Size(width: width, height: height))
    }
}
