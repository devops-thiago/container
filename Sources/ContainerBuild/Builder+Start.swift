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
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import NIO
import TerminalProgress

extension Builder {
    /// The folder under the engine's app root that the builder exports into, mounted in the
    /// builder container as `/var/lib/container-builder-shim/exports`.
    public static let resourceDirectory = "builder"

    /// The vsock port the builder shim listens on.
    public static let defaultVsockPort: UInt32 = 8088

    /// How the builder container should be started.
    public struct StartOptions: Sendable, Equatable {
        /// CPUs for the builder; `nil` takes `build.cpus` from the system configuration.
        public var cpus: Int64?
        /// Memory for the builder, with an optional K, M, G, T or P suffix; `nil` takes
        /// `build.memory` from the system configuration.
        public var memory: String?
        /// Forward the caller's SSH agent into the builder. Takes effect only when
        /// `SSH_AUTH_SOCK` is set.
        public var ssh: Bool
        public var dnsNameservers: [String]
        public var dnsDomain: String?
        public var dnsSearchDomains: [String]
        public var dnsOptions: [String]

        public init(
            cpus: Int64? = nil,
            memory: String? = nil,
            ssh: Bool = false,
            dnsNameservers: [String] = [],
            dnsDomain: String? = nil,
            dnsSearchDomains: [String] = [],
            dnsOptions: [String] = []
        ) {
            self.cpus = cpus
            self.memory = memory
            self.ssh = ssh
            self.dnsNameservers = dnsNameservers
            self.dnsDomain = dnsDomain
            self.dnsSearchDomains = dnsSearchDomains
            self.dnsOptions = dnsOptions
        }
    }

    /// The builder container that a start asks for, resolved against the system
    /// configuration and the caller's environment.
    public struct StartSpec: Sendable {
        /// The BuildKit image reference.
        public var image: String
        public var resources: ContainerConfiguration.Resources
        /// The environment variables the start manages (`BUILDKIT_COLORS`, `NO_COLOR`), sorted.
        public var managedEnvironment: [String]
        /// Whether the SSH agent is forwarded: asked for, and `SSH_AUTH_SOCK` is set.
        public var ssh: Bool
        public var dnsNameservers: [String]
        public var dnsDomain: String?
        public var dnsSearchDomains: [String]
        public var dnsOptions: [String]

        public init(
            options: StartOptions,
            containerSystemConfig: ContainerSystemConfig,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws {
            self.image = containerSystemConfig.build.image
            self.resources = try Parser.resources(
                cpus: options.cpus,
                memory: options.memory,
                defaultCPUs: containerSystemConfig.build.cpus,
                defaultMemory: containerSystemConfig.build.memory,
            )
            self.managedEnvironment = Builder.managedEnvironment(environment)
            self.ssh = options.ssh && environment["SSH_AUTH_SOCK"] != nil
            self.dnsNameservers = options.dnsNameservers
            self.dnsDomain = options.dnsDomain
            self.dnsSearchDomains = options.dnsSearchDomains
            self.dnsOptions = options.dnsOptions
        }

        /// Whether a builder created from `existing` differs from this one in a way that needs
        /// a new container: image, CPUs, memory, managed environment, SSH forwarding, or DNS.
        ///
        /// DNS compares only the first field this start sets, in the order nameservers,
        /// domain, search domains, options; a start that sets none keeps any DNS.
        public func requiresRecreate(_ existing: ContainerConfiguration) -> Bool {
            let existingManagedEnv = existing.initProcess.environment.filter { envVar in
                envVar.hasPrefix("BUILDKIT_COLORS=") || envVar.hasPrefix("NO_COLOR=")
            }.sorted()
            let envChanged = existingManagedEnv != managedEnvironment
            let imageChanged = existing.image.reference != image
            let cpuChanged = existing.resources.cpus != resources.cpus
            let memChanged = existing.resources.memoryInBytes != resources.memoryInBytes
            let sshChanged = existing.ssh != ssh
            let existingDNS = existing.dns
            let dnsChanged = {
                if !dnsNameservers.isEmpty {
                    return existingDNS?.nameservers != dnsNameservers
                }
                if dnsDomain != nil {
                    return existingDNS?.domain != dnsDomain
                }
                if !dnsSearchDomains.isEmpty {
                    return existingDNS?.searchDomains != dnsSearchDomains
                }
                if !dnsOptions.isEmpty {
                    return existingDNS?.options != dnsOptions
                }
                return false
            }()
            return imageChanged || cpuChanged || memChanged || envChanged || dnsChanged || sshChanged
        }
    }

    /// What a start does with the builder container it finds.
    public enum StartAction: Sendable, Equatable {
        /// No usable container: create one and start it.
        case create
        /// Running and matching: use it as it is.
        case reuse
        /// Running but different: stop and delete it, then create a new one.
        case stopAndRecreate
        /// Stopped and matching: start it again, recreating it if that fails.
        case restart
        /// Stopped and different: delete it, then create a new one.
        case deleteAndRecreate
    }

    /// Decide what a start does with an existing builder in `status`. Throws while the
    /// builder is stopping or restarting, since neither can be acted on yet.
    public static func startAction(status: RuntimeStatus?, requiresRecreate: Bool) throws -> StartAction {
        switch status {
        case nil, .unknown:
            return .create
        case .running:
            return requiresRecreate ? .stopAndRecreate : .reuse
        case .stopped:
            return requiresRecreate ? .deleteAndRecreate : .restart
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "builder is stopping, please wait until it is fully stopped before proceeding"
            )
        case .restarting:
            throw ContainerizationError(
                .invalidState,
                message: "builder is restarting, please stop it or wait until it is running before proceeding"
            )
        }
    }

    /// The `BUILDKIT_COLORS` and `NO_COLOR` settings from `environment` that the builder
    /// container carries, sorted.
    public static func managedEnvironment(_ environment: [String: String]) -> [String] {
        var targetEnvVars: [String] = []
        if let buildkitColors = environment["BUILDKIT_COLORS"] {
            targetEnvVars.append("BUILDKIT_COLORS=\(buildkitColors)")
        }
        if environment["NO_COLOR"] != nil {
            targetEnvVars.append("NO_COLOR=true")
        }
        targetEnvVars.sort()
        return targetEnvVars
    }

    /// Start the builder container, or make sure it is running, the way
    /// `container builder start` does.
    ///
    /// An existing builder is kept when it matches `options`; one that differs in image,
    /// CPUs, memory, managed environment, SSH forwarding or DNS is replaced (see
    /// ``StartSpec/requiresRecreate(_:)``). Progress is reported in four tasks: fetching the
    /// BuildKit image, unpacking it, fetching the kernel, starting the container.
    public static func start(
        _ options: StartOptions,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws {
        await progressUpdate([
            .setDescription("Fetching BuildKit image"),
            .setItemsName("blobs"),
        ])
        let taskManager = ProgressTaskCoordinator()
        let fetchTask = await taskManager.startTask()

        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportsMount: String = systemHealth.appRoot
            .appendingPathComponent(resourceDirectory)
            .absolutePath()

        if !FileManager.default.fileExists(atPath: exportsMount) {
            try FileManager.default.createDirectory(
                atPath: exportsMount,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let target = try StartSpec(options: options, containerSystemConfig: containerSystemConfig)

        let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

        let client = ContainerClient()
        if let existingContainer = try? await client.get(id: builderContainerId) {
            let action = try startAction(
                status: existingContainer.status,
                requiresRecreate: target.requiresRecreate(existingContainer.configuration)
            )
            switch action {
            case .reuse:
                return
            case .stopAndRecreate:
                try await client.stop(id: existingContainer.id)
                try await client.delete(id: existingContainer.id)
            case .deleteAndRecreate:
                try? await client.delete(id: existingContainer.id)
            case .restart:
                do {
                    try await startBuildKit(client: client, id: existingContainer.id, progressUpdate, nil)
                    return
                } catch {
                    log.warning(
                        "failed to restart existing stopped BuildKit container, recreating it",
                        metadata: [
                            "id": "\(existingContainer.id)",
                            "error": "\(error)",
                        ])
                }
                try? await client.delete(id: existingContainer.id)
            case .create:
                break
            }
        }

        let useRosetta = containerSystemConfig.build.rosetta
        let shimArguments = [
            "--debug",
            "--vsock",
            useRosetta ? nil : "--enable-qemu",
        ].compactMap { $0 }

        guard ManagedContainer.nameValid(builderContainerId) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(builderContainerId) is not a valid container ID")
        }

        let image = try await ClientImage.fetch(
            reference: target.image,
            platform: builderPlatform,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressUpdate)
        )
        // Unpack fetched image before use
        await progressUpdate([
            .setDescription("Unpacking BuildKit image"),
            .setItemsName("entries"),
        ])

        let unpackTask = await taskManager.startTask()
        _ = try await image.getCreateSnapshot(
            platform: builderPlatform,
            progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressUpdate)
        )

        let imageDesc = ImageDescription(
            reference: target.image,
            descriptor: image.descriptor
        )

        let imageConfig = try await image.config(for: builderPlatform).config
        var environment = imageConfig?.env ?? []
        environment.append(contentsOf: target.managedEnvironment)

        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: shimArguments,
            environment: environment,
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDesc, process: processConfig)
        config.resources = target.resources
        config.ssh = target.ssh
        config.labels = [
            ResourceLabelKeys.plugin: "builder",
            ResourceLabelKeys.role: ResourceRoleValues.builder,
        ]
        config.capAdd = ["ALL"]
        config.mounts = [
            .init(
                type: .tmpfs,
                source: "",
                destination: "/run",
                options: []
            ),
            .init(
                type: .virtiofs,
                source: exportsMount,
                destination: "/var/lib/container-builder-shim/exports",
                options: []
            ),
        ]
        // Enable Rosetta only if the user didn't ask to disable it
        config.rosetta = useRosetta

        let networkClient = NetworkClient()
        guard let defaultNetwork = try await networkClient.builtin else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        config.networks = [
            AttachmentConfiguration(network: defaultNetwork.id, options: AttachmentOptions(hostname: builderContainerId))
        ]
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: target.dnsNameservers,
            domain: target.dnsDomain,
            searchDomains: target.dnsSearchDomains,
            options: target.dnsOptions
        )

        let kernel = try await {
            await progressUpdate([
                .setDescription("Fetching kernel"),
                .setItemsName("binary"),
            ])

            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            return kernel
        }()

        await progressUpdate([
            .setDescription("Starting BuildKit container")
        ])

        do {
            try await client.create(
                configuration: config,
                options: .default,
                kernel: kernel
            )
        } catch let error as ContainerizationError where error.code == .exists {
            // A concurrent `container build` invocation already created the builder
            // while we were fetching the image/kernel above. `bootstrap` below is
            // idempotent, so just proceed against the container the winner created.
        }

        try await startBuildKit(client: client, id: builderContainerId, progressUpdate, taskManager)
        log.debug("starting BuildKit and BuildKit-shim")
    }

    /// Start the builder when it needs it, then connect to BuildKit in it, the way
    /// `container build` does.
    ///
    /// Reports "Dialing builder" first, then the start's own progress. When a dial fails the
    /// builder is started again and the dial retried, until `timeout` passes.
    public static func connect(
        _ options: StartOptions,
        vsockPort: UInt32 = defaultVsockPort,
        timeout: Duration = .seconds(300),
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws -> Builder {
        await progressUpdate([.setDescription("Dialing builder")])

        // Ensure the builder is started (or restarted) with the correct SSH configuration
        // before attempting to dial. This handles the case where the builder is already
        // running but was not started with SSH forwarding enabled.
        try await start(options, containerSystemConfig: containerSystemConfig, log: log, progressUpdate: progressUpdate)

        let builder: Builder? = try await withThrowingTaskGroup(of: Builder.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                let client = ContainerClient()
                while true {
                    do {
                        let fh = try await client.dial(id: builderContainerId, port: vsockPort)

                        let threadGroup: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                        let b = try await Builder(socket: fh, group: threadGroup, logger: log)

                        // If this call succeeds, then BuildKit is running.
                        let _ = try await b.info()
                        return b
                    } catch {
                        // If we get here, "Dialing builder" is shown for such a short period
                        // of time that it's invisible to the user.
                        await progressUpdate([.setTasks(0), .setTotalTasks(3)])

                        try await start(options, containerSystemConfig: containerSystemConfig, log: log, progressUpdate: progressUpdate)

                        // wait (seconds) for builder to start listening on vsock
                        try await Task.sleep(for: .seconds(5))
                        continue
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectError.timeout
            }

            return try await group.next()
        }

        guard let builder else {
            throw ConnectError.notRunning
        }
        return builder
    }

    /// Why ``connect(_:vsockPort:timeout:containerSystemConfig:log:progressUpdate:)`` gave up.
    public enum ConnectError: Swift.Error, CustomStringConvertible, Equatable {
        /// No connection to BuildKit within the timeout.
        case timeout
        /// The connection task ended without a builder.
        case notRunning

        public var description: String {
            switch self {
            case .timeout:
                // Indented as the CLI has always printed it.
                return "    Timeout waiting for connection to builder"
            case .notRunning:
                return "builder is not running"
            }
        }
    }
}

// MARK: - BuildKit Start Helper

/// Starts the BuildKit process within the container
/// This function handles bootstrapping the container and starting the BuildKit process
private func startBuildKit(
    client: ContainerClient,
    id: String,
    _ progress: @escaping ProgressUpdateHandler,
    _ taskManager: ProgressTaskCoordinator? = nil
) async throws {
    do {
        let io = try ProcessIO.create(
            tty: false,
            interactive: false,
            detach: true
        )
        defer { try? io.close() }

        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }

        let process = try await client.bootstrap(id: id, stdio: io.stdio, dynamicEnv: dynamicEnv)
        try await process.start()
        await taskManager?.finish()
        try io.closeAfterStart()
    } catch {
        try? await client.stop(id: id)
        try? await client.delete(id: id)
        if error is ContainerizationError {
            throw error
        }
        throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
    }
}
