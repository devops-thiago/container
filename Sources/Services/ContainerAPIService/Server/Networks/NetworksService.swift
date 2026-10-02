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
import ContainerNetworkClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

public actor NetworksService {
    struct NetworkEntry {
        var configuration: NetworkConfiguration
        var status: NetworkStatus
        var client: ContainerNetworkClient.NetworkClient
    }

    private let pluginLoader: PluginLoader
    private let resourceRoot: FilePath
    private let containersService: ContainersService
    private let log: Logger
    private let debugHelpers: Bool
    private let defaultNetworkConfiguration: NetworkConfiguration

    private let store: FilesystemEntityStore<NetworkConfiguration>
    private let networkPlugins: [Plugin]
    private var busyNetworks = Set<String>()

    private let stateLock = AsyncLock()
    private var serviceStates = [String: NetworkEntry]()

    /// One open session per attachment of every container that exists, started or not. The
    /// network helper keeps an address for as long as a session holds its hostname, so the
    /// container has its address, and its peers have its name, from create to delete.
    private var reservations = [String: [XPCClientSession]]()

    public init(
        pluginLoader: PluginLoader,
        resourceRoot: FilePath,
        containersService: ContainersService,
        defaultNetworkConfiguration: NetworkConfiguration,
        log: Logger,
        debugHelpers: Bool = false,
    ) async throws {
        self.pluginLoader = pluginLoader
        self.resourceRoot = resourceRoot
        self.containersService = containersService
        self.log = log
        self.debugHelpers = debugHelpers

        try FileManager.default.createDirectory(atPath: resourceRoot.string, withIntermediateDirectories: true)
        self.store = try FilesystemEntityStore<NetworkConfiguration>(
            path: resourceRoot,
            type: "network",
            log: log
        )

        let networkPlugins =
            pluginLoader
            .findPlugins()
            .filter { $0.hasType(.network) }
        guard !networkPlugins.isEmpty else {
            throw ContainerizationError(.internalError, message: "cannot find any plugins with type network")
        }
        self.networkPlugins = networkPlugins

        self.defaultNetworkConfiguration = defaultNetworkConfiguration
    }

    /// Start every network already in the store, and create the built-in one if
    /// it is missing.
    ///
    /// Deliberately not part of `init`: starting a network spawns a helper that
    /// announces its endpoint back to the apiserver, so this cannot run until
    /// the apiserver's XPC listener is accepting connections. Called from
    /// APIServer.Start once the listener is up.
    public func startPersistedNetworks() async {
        let configurations = (try? await store.list()) ?? []
        for configuration in configurations {
            var effectiveConfiguration = configuration

            // If there's a default network in the store, always update it with the
            // computed default network configuration from the apiserver to ensure we
            // have the correct default values configured.
            if effectiveConfiguration.id == NetworkClient.defaultNetworkName {
                effectiveConfiguration = defaultNetworkConfiguration
                try? await store.update(effectiveConfiguration)
            }

            // Start up the network.
            // This call will normally take ~20-100ms to complete after service
            // registration, but on a fresh system (e.g. CI runner), it may take
            // 5 seconds or considerably more from the registration of this first
            // network service to its execution.
            do {
                try await registerService(configuration: effectiveConfiguration)
                let client = try Self.getClient(configuration: effectiveConfiguration)
                let networkStatus = try await client.status()
                serviceStates[effectiveConfiguration.id] = NetworkEntry(
                    configuration: effectiveConfiguration,
                    status: networkStatus,
                    client: client
                )
                log.info("started network", metadata: ["id": "\(effectiveConfiguration.id)"])
            } catch {
                log.error(
                    "failed to start network",
                    metadata: [
                        "id": "\(effectiveConfiguration.id)",
                        "error": "\(error)",
                    ])
            }
        }

        guard serviceStates[defaultNetworkConfiguration.id] == nil else { return }
        do {
            log.info("creating default network")
            _ = try await create(configuration: defaultNetworkConfiguration)
        } catch {
            log.error("failed to create default network: \(error)")
        }
    }

    /// Hold an address for each of a container's attachments until `releaseAddresses`.
    ///
    /// Called at create, and again for every container when the engine starts, since a
    /// helper that was restarted has forgotten what it handed out. Doing it twice for one
    /// container is harmless.
    public func reserveAddresses(for container: String, attachments: [AttachmentConfiguration]) async throws {
        guard reservations[container] == nil, !attachments.isEmpty else { return }
        var sessions: [XPCClientSession] = []
        do {
            for attachment in attachments {
                // A network that is not up yet is not this container's failure: its runtime
                // allocates at start, as it always has, and the next engine start reserves.
                guard let entry = serviceStates[attachment.network] else {
                    log.info("network not running; address not reserved", metadata: ["id": "\(container)", "network": "\(attachment.network)"])
                    continue
                }
                let session = entry.client.connect()
                sessions.append(session)
                do {
                    _ = try await entry.client.allocate(
                        hostname: attachment.options.hostname,
                        macAddress: attachment.options.macAddress,
                        aliases: attachment.options.aliases,
                        on: session)
                } catch {
                    throw ContainerizationError(
                        .invalidState,
                        message:
                            "network \(attachment.network) has no address to give \(container): every address of its subnet may be held by a container; delete one, or use a network with a larger subnet",
                        cause: error)
                }
            }
        } catch {
            for session in sessions { session.close() }
            throw error
        }
        reservations[container] = sessions
        log.info("reserved addresses", metadata: ["id": "\(container)", "attachments": "\(attachments.count)"])
    }

    /// Give back the addresses held for a container that no longer exists.
    public func releaseAddresses(for container: String) {
        guard let sessions = reservations.removeValue(forKey: container) else { return }
        for session in sessions { session.close() }
        log.info("released addresses", metadata: ["id": "\(container)"])
    }

    /// List all networks registered with the service.
    public func list() async throws -> [NetworkResource] {
        log.debug("NetworksService: enter", metadata: ["func": "\(#function)"])
        defer { log.debug("NetworksService: exit", metadata: ["func": "\(#function)"]) }

        return serviceStates.values
            .map { NetworkResource(configuration: $0.configuration, status: $0.status) }
            .sorted { $0.id < $1.id }
    }

    /// Create a new network from the provided configuration.
    public func create(configuration: NetworkConfiguration) async throws -> NetworkResource {
        log.debug(
            "NetworksService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "NetworksService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        //Ensure that the network is not named "none"
        if configuration.id == NetworkClient.noNetworkName {
            throw ContainerizationError(.unsupported, message: "network \(configuration.id) is not a valid name")
        }

        // Ensure nobody is manipulating the network already.
        guard !busyNetworks.contains(configuration.id) else {
            throw ContainerizationError(.exists, message: "network \(configuration.id) has a pending operation")
        }

        busyNetworks.insert(configuration.id)
        defer { busyNetworks.remove(configuration.id) }

        // Ensure the network doesn't already exist.
        return try await self.stateLock.withLock { _ in
            guard await self.serviceStates[configuration.id] == nil else {
                throw ContainerizationError(.exists, message: "network \(configuration.id) already exists")
            }

            // Create and start the network.
            try await self.registerService(configuration: configuration)
            let client = try Self.getClient(configuration: configuration)

            // Ensure the network is running
            let networkStatus = try await client.status()

            let finalConfiguration = try NetworkConfiguration(
                name: configuration.name,
                mode: configuration.mode,
                ipv4Subnet: configuration.ipv4Subnet,
                ipv6Subnet: configuration.ipv6Subnet,
                labels: configuration.labels,
                plugin: configuration.plugin,
                options: configuration.options
            )

            let entry = NetworkEntry(configuration: finalConfiguration, status: networkStatus, client: client)
            await self.setServiceState(key: finalConfiguration.id, value: entry)

            // Persist the configuration data. An entity left in the store by a
            // previous run is adopted rather than treated as a conflict: live
            // state is what `serviceStates` says, and it was checked above.
            do {
                do {
                    try await self.store.create(finalConfiguration)
                } catch {
                    try await self.store.update(finalConfiguration)
                }
                return NetworkResource(configuration: finalConfiguration, status: networkStatus)
            } catch {
                await self.removeServiceState(key: finalConfiguration.id)
                do {
                    try await self.deregisterService(configuration: finalConfiguration)
                } catch {
                    self.log.error(
                        "failed to deregister network service after failed creation",
                        metadata: [
                            "id": "\(finalConfiguration.id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
                throw error
            }
        }
    }

    /// Delete a network.
    public func delete(id: String) async throws {
        log.debug(
            "NetworksService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "NetworksService: enter",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // check actor busy state
        guard !busyNetworks.contains(id) else {
            throw ContainerizationError(.exists, message: "network \(id) has a pending operation")
        }

        // make actor state busy for this network
        busyNetworks.insert(id)
        defer { busyNetworks.remove(id) }

        log.info(
            "deleting network",
            metadata: [
                "id": "\(id)"
            ]
        )

        try await stateLock.withLock { _ in
            guard let serviceState = await self.serviceStates[id] else {
                throw ContainerizationError(.notFound, message: "no network for id \(id)")
            }

            // basic sanity checks on network itself
            if serviceState.configuration.labels.isBuiltin {
                throw ContainerizationError(.invalidArgument, message: "cannot delete builtin network: \(id)")
            }

            // prevent container operations while we atomically check and delete
            try await self.containersService.withContainerList(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { containers in
                // find all containers that refer to the network
                var referringContainers = Set<String>()
                for container in containers {
                    for attachmentConfiguration in container.configuration.networks {
                        if attachmentConfiguration.network == id {
                            referringContainers.insert(container.configuration.id)
                            break
                        }
                    }
                }

                // bail if any referring containers
                guard referringContainers.isEmpty else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "cannot delete subnet \(id) with referring containers: \(referringContainers.joined(separator: ", "))"
                    )
                }

                // start network deletion, this is the last place we'll want to throw
                do {
                    try await self.deregisterService(configuration: serviceState.configuration)
                } catch {
                    self.log.error(
                        "failed to deregister network service",
                        metadata: [
                            "id": "\(id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }

                // deletion is underway, do not throw anything now
                do {
                    try await self.store.delete(id)
                } catch {
                    self.log.error(
                        "failed to delete network from configuration store",
                        metadata: [
                            "id": "\(id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
            }

            // having deleted successfully, remove the runtime state
            await self.removeServiceState(key: id)
        }
    }

    /// Perform a hostname lookup on all networks.
    ///
    /// - Parameter hostname: A canonical DNS hostname with a trailing dot (e.g. `"example.com."`).
    public func lookup(hostname: String) async throws -> Attachment? {
        try await self.stateLock.withLock { _ in
            for state in await self.serviceStates.values {
                guard let allocation = try await state.client.lookup(hostname: hostname) else {
                    continue
                }
                return allocation
            }
            return nil
        }
    }

    public func plugin(for id: String) throws -> String {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        return serviceState.configuration.plugin
    }

    private static func getClient(configuration: NetworkConfiguration) throws -> ContainerNetworkClient.NetworkClient {
        NetworkClient(id: configuration.id, plugin: configuration.plugin)
    }

    private func registerService(configuration: NetworkConfiguration) async throws {
        guard configuration.mode == .nat || configuration.mode == .hostOnly else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
        }

        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == configuration.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(configuration.plugin)"
            )
        }

        guard let serviceIdentifier = networkPlugin.getMachService(instanceId: configuration.id, type: .network) else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
        }
        var args = [
            "start",
            "--id",
            configuration.id,
            "--service-identifier",
            serviceIdentifier,
            "--mode",
            configuration.mode.rawValue,
        ]
        if debugHelpers {
            args.append("--debug")
        }

        if let ipv4Subnet = configuration.ipv4Subnet {
            var existingCidrs: [CIDRv4] = []
            for serviceState in serviceStates.values {
                existingCidrs.append(serviceState.status.ipv4Subnet)
            }
            let overlap = existingCidrs.first {
                $0.contains(ipv4Subnet.lower)
                    || $0.contains(ipv4Subnet.upper)
                    || ipv4Subnet.contains($0.lower)
                    || ipv4Subnet.contains($0.upper)
            }
            if let overlap {
                throw ContainerizationError(.exists, message: "IPv4 subnet \(ipv4Subnet) overlaps an existing network with subnet \(overlap)")
            }

            args += ["--subnet", ipv4Subnet.description]
        }

        if let ipv6Subnet = configuration.ipv6Subnet {
            var existingCidrs: [CIDRv6] = []
            for serviceState in serviceStates.values {
                if let otherIPv6Subnet = serviceState.status.ipv6Subnet {
                    existingCidrs.append(otherIPv6Subnet)
                }
            }
            let overlap = existingCidrs.first {
                $0.contains(ipv6Subnet.lower)
                    || $0.contains(ipv6Subnet.upper)
                    || ipv6Subnet.contains($0.lower)
                    || ipv6Subnet.contains($0.upper)
            }
            if let overlap {
                throw ContainerizationError(.exists, message: "IPv6 subnet \(ipv6Subnet) overlaps an existing network with subnet \(overlap)")
            }

            args += ["--subnet-v6", ipv6Subnet.description]
        }

        if let variant = configuration.options["variant"] {
            args += ["--variant", variant]
        }

        let entityPath = try store.entityPath(configuration.id)
        try pluginLoader.registerWithLaunchd(
            plugin: networkPlugin,
            pluginStateRoot: URL(filePath: entityPath.string),
            args: args,
            instanceId: configuration.id
        )
    }

    private func deregisterService(configuration: NetworkConfiguration) async throws {
        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == configuration.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(configuration.plugin)"
            )
        }
        try self.pluginLoader.deregisterWithLaunchd(plugin: networkPlugin, instanceId: configuration.id)
    }
}

extension NetworksService {
    private func removeServiceState(key: String) {
        self.serviceStates.removeValue(forKey: key)
    }

    private func setServiceState(key: String, value: NetworkEntry) {
        self.serviceStates[key] = value
    }
}
