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

import CVersion
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerVersion
import ContainerXPC
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

private struct IncarnationMigrationFailure: Error {}

/// A folder the container mounts that nothing grants, met by a start the engine makes by
/// itself, which never asks the user for one.
struct HostDirectoryNotGranted: Error, CustomStringConvertible {
    let source: String

    var description: String {
        "cannot mount \(source): no permission for that folder, and the engine does not ask for one when it starts a container by itself. Start the container from SiliconShip, or from the command line while SiliconShip is open, to grant it."
    }
}

public actor ContainersService {
    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: RuntimeClient? = nil
        /// What the restart policy remembers across engine restarts; mirrored on disk.
        var restartRecord = RestartRecord()
        var backoff = RestartBackoff()
        /// Identifies the runtime the current bootstrap made. An exit or a stop completion is
        /// for the run it observed, and must not end a later run of the same incarnation.
        var run: UUID? = nil
        /// A stop or a kill was asked for this run, so its end does not start it again.
        var exitRequested = false
        /// The restart waiting out its delay, while the status is `.restarting`.
        var pendingRestart: UUID? = nil
        var pendingRestartTask: Task<Void, Never>? = nil
        /// What the last start passed to the runtime, for the engine's own starts of it.
        var dynamicEnv: [String: String] = [:]
        /// Follows the runtime's health check for this run, when the container has one.
        var healthWatch: Task<Void, Never>? = nil

        /// Forget the restart waiting out its delay, if there is one.
        mutating func cancelPendingRestart() {
            pendingRestartTask?.cancel()
            pendingRestartTask = nil
            pendingRestart = nil
        }

        /// The run is over: stop following its health check, and leave the health as Docker
        /// leaves a stopped container's.
        mutating func endHealthWatch() {
            healthWatch?.cancel()
            healthWatch = nil
            snapshot.health = HealthWatch.ended(snapshot.health)
        }

        func getClient() throws -> RuntimeClient {
            guard let client else {
                var message = "no runtime client exists"
                if snapshot.status == .stopped {
                    message += ": container is stopped"
                }
                throw ContainerizationError(.invalidState, message: message)
            }
            return client
        }
    }

    private let log: Logger
    private let debugHelpers: Bool
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor
    private let containerSystemConfig: ContainerSystemConfig
    /// Waits out a restart delay. Injected so that tests do not wait.
    private let restartDelay: @Sendable (Duration) async throws -> Void
    /// Set once the engine starts going down: nothing ending from then on is restarted, and
    /// no stop from then on is a person's.
    private var engineShuttingDown = false

    private static let hostDirectoryBookmarksFilename = "host-directory-bookmarks.json"
    /// Persisted beside, but never inside, the user-supplied container configuration.
    private static let incarnationFilename = "incarnation"

    private let lock: AsyncLock
    private var containers: [String: ContainerState]
    /// Host directories a sandboxed embedder has granted, per container. Inert unsandboxed.
    private let hostDirectoryAccess: HostDirectoryAccess

    // FIXME: Find a better mechanism for services running on the APIServer to work with each other
    private weak var networksService: NetworksService?
    /// Rewrites running peers' hosts files; made on the first change that needs it.
    private var peerHosts: PeerHostsRefresher?
    /// How long one guest has to take its new hosts file. The operation that caused the
    /// rewrite waits for it, so a wedged guest must not hold that up for long.
    private static let peerHostsResponseTimeout: Duration = .seconds(5)

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        debugHelpers: Bool = false,
        restartDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        self.exitMonitor = ExitMonitor(log: log)
        self.lock = AsyncLock(log: log)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.containerSystemConfig = containerSystemConfig
        self.log = log
        self.debugHelpers = debugHelpers
        self.restartDelay = restartDelay
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.hostDirectoryAccess = HostDirectoryAccess(log: log)
        self.containers = try Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
    }

    static func loadAtBoot(root: URL, loader: PluginLoader, log: Logger) throws -> [String: ContainerState] {
        var directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        directories = directories.filter {
            $0.isDirectory
        }

        let runtimePlugins = loader.findPlugins().filter { $0.hasType(.runtime) }
        var results = [String: ContainerState]()
        for dir in directories {
            var autoRemove = false
            do {
                let (config, options) = try Self.getContainerConfiguration(at: dir)
                autoRemove = options?.autoRemove ?? false
                if autoRemove {
                    log.info(
                        "reap auto-remove container",
                        metadata: [
                            "id": "\(config.id)"
                        ])

                    let label = try loader.fullLaunchdLabel(
                        pluginName: config.runtimeHandler,
                        instanceId: config.id)

                    var status: Int32 = -1
                    try? ServiceManager.deregister(fullServiceLabel: label, status: &status)
                    if status != 0 {
                        log.warning(
                            "failed to deregister service",
                            metadata: [
                                "id": "\(config.id)",
                                "service": "\(label)",
                                "status": "\(status)",
                            ]
                        )
                    }

                    let bundle = ContainerResource.Bundle(path: dir)
                    try Self.removePersistedHostDirectoryBookmarks(at: dir)
                    try? bundle.delete()
                    continue
                }

                // A missing plugin can be restored. Validate before migrating the bundle
                // or publishing a stopped container that cannot actually be recovered.
                guard runtimePlugins.contains(where: { $0.name == config.runtimeHandler }) else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to find runtime plugin \(config.runtimeHandler); restore the plugin and restart the engine"
                    )
                }
                let bundle = ContainerResource.Bundle(path: dir)
                let exit = bundle.exitStatus
                let restartRecord = bundle.restartRecord
                let incarnation: String
                do {
                    incarnation = try Self.loadOrCreateIncarnation(at: dir)
                } catch {
                    // A legacy bundle that cannot persist its new identity is still valid
                    // user data. Fail closed rather than publishing a mutable identity.
                    log.error(
                        "failed to persist container incarnation",
                        metadata: ["path": "\(dir.path)", "error": "\(error)"])
                    throw IncarnationMigrationFailure()
                }
                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        incarnation: incarnation,
                        status: .stopped,
                        networks: [],
                        startedDate: nil,
                        exitCode: exit?.exitCode,
                        exitedAt: exit?.exitedAt,
                        restartCount: restartRecord.restartCount
                    ),
                    restartRecord: restartRecord
                )
                results[config.id] = state
            } catch is IncarnationMigrationFailure {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to persist an immutable identity for container at \(dir.path)")
            } catch {
                if autoRemove {
                    // In particular, never continue auto-removal when persisted
                    // authorization could not be removed first.
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to reap auto-remove container at \(dir.path); bundle preserved",
                        cause: error
                    )
                }
                // Ordinary recovery failures are not deletion requests. Preserve all
                // recovery material, including inert bookmarks; no state or grants for
                // this container have been published. Only explicit removal and the
                // auto-remove policy may discard its writable filesystem.
                log.warning(
                    "failed to load container; bundle preserved; repair the reported cause and restart the engine",
                    metadata: [
                        "path": "\(dir.path)",
                        "error": "\(error)",
                    ])
            }
        }
        return results
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let matcher = try ContainerListMatcher(filters)
        return self.containers.values.compactMap { state in
            matcher.admits(state.snapshot) ? state.snapshot : nil
        }
    }

    /// Execute an operation with the current container list while maintaining atomicity
    /// This prevents race conditions where containers are created during the operation
    public func withContainerList<T: Sendable>(
        logMetadata: Logger.Metadata? = nil,
        _ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T
    ) async throws -> T {
        try await lock.withLock(logMetadata: logMetadata) { context in
            let snapshots = await self.containers.values.map { $0.snapshot }
            return try await operation(snapshots)
        }
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var totalSize: UInt64 = 0
            var reclaimableSize: UInt64 = 0
            var activeCount = 0

            for (id, state) in await self.containers {
                let bundlePath = self.containerRoot.appendingPathComponent(id)
                let containerSize = FileManager.default.allocatedSize(of: bundlePath)
                totalSize += containerSize

                // A container waiting to be restarted is about to run again, and prune
                // leaves it alone, so it is not reclaimable.
                if state.snapshot.status == .running || state.snapshot.status == .restarting {
                    activeCount += 1
                } else {
                    // Stopped containers are reclaimable
                    reclaimableSize += containerSize
                }
            }

            return (await self.containers.count, activeCount, totalSize, reclaimableSize)
        }
    }

    /// Get set of image references used by containers (for disk usage calculation)
    /// - Returns: Set of image references currently in use
    public func getActiveImageReferences() async -> Set<String> {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var imageRefs = Set<String>()
            for (_, state) in await self.containers {
                imageRefs.insert(state.snapshot.configuration.image.reference)
            }
            return imageRefs
        }
    }

    /// Create a new container from the provided id and configuration.
    /// - Parameter hostDirectoryBookmarks: grants for host directories this container
    ///   bind-mounts, made by a sandboxed embedder. Persisted with the container and resolved
    ///   only after every throwing create operation, so failed creates cannot retain access.
    @discardableResult
    public func create(
        configuration: ContainerConfiguration, kernel: Kernel, options: ContainerCreateOptions, initImage: String? = nil, runtimeData: Data? = nil,
        hostDirectoryBookmarks: [Data] = [], incarnation requestedIncarnation: String? = nil
    ) async throws -> String {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        // Validate before allocating snapshots, starting a runtime, or persisting a
        // stopped container that can never boot. This also covers non-CLI clients.
        if configuration.networks.isEmpty,
            let host = configuration.extraHosts.first(where: { $0.address == ContainerConfiguration.ExtraHost.hostGateway })
        {
            throw ContainerizationError(
                .invalidArgument,
                message: "host '\(host.name)' asks for host-gateway, but the container has no network to reach the host through")
        }

        return try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(configuration.id)"]) { context in
            let path = self.containerRoot.appendingPathComponent(configuration.id)
            guard await self.containers[configuration.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container already exists: \(configuration.id)"
                )
            }
            // Failed recovery deliberately leaves data outside the loaded-state map.
            // Reusing that ID must not overwrite it or let create's rollback delete it.
            guard !FileManager.default.fileExists(atPath: path.path) else {
                throw ContainerizationError(
                    .exists,
                    message: "container recovery data already exists at \(path.path); repair or move the preserved bundle before reusing this ID"
                )
            }

            var allHostnames = Set<String>()
            for container in await self.containers.values {
                for attachmentConfiguration in container.snapshot.configuration.networks {
                    allHostnames.insert(attachmentConfiguration.options.hostname)
                }
            }

            var conflictingHostnames = [String]()
            for attachmentConfiguration in configuration.networks {
                if allHostnames.contains(attachmentConfiguration.options.hostname) {
                    conflictingHostnames.append(attachmentConfiguration.options.hostname)
                }
            }

            guard conflictingHostnames.isEmpty else {
                throw ContainerizationError(
                    .exists,
                    message: "hostname(s) already exist: \(conflictingHostnames)"
                )
            }

            guard self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) != nil else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(configuration.runtimeHandler)"
                )
            }

            // Protect against a user providing a memory amount that will cause us to not be able
            // to boot. We can go lower, but this is a somewhat safe threshold. Containerization
            // also gives a little bit extra than the user asked for to account for guest agent overhead.
            //
            // NOTE: We could potentially leave this validation to the runtime service(s), as
            // it's possible there could be an implementation that can get away with a lower
            // amount and be perfectly safe.
            let minimumMemory: UInt64 = 200.mib()
            guard configuration.resources.memoryInBytes >= minimumMemory else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "minimum memory amount allowed is 200 MiB (got \(configuration.resources.memoryInBytes) bytes)"
                )
            }

            // Bookmarks the caller supplied, or — for the CLI, which has none — whatever the
            // boot-wide pool already holds / can obtain from the embedder. The static file
            // exceptions that used to cover home and /Volumes are gone (QA1773), so every
            // virtiofs source needs a grant from somewhere.
            let requiredHostDirectoryBookmarks =
                ServiceIdentity.appGroup != nil && configuration.mounts.contains { $0.isVirtiofs }
                ? hostDirectoryBookmarks : []
            if ServiceIdentity.appGroup != nil {
                try await self.ensurePoolCoversBindMounts(of: configuration)
            }
            let systemPlatform = kernel.platform

            // Fetch init image (custom or default)
            self.log.debug(
                "ContainersService: get init block",
                metadata: [
                    "id": "\(configuration.id)"
                ]
            )
            let initFilesystem = try await self.getInitBlock(for: systemPlatform.ociPlatform(), imageRef: initImage)

            // The address is the container's from here to its delete (and its name its peers'
            // to resolve), so a subnet with none left fails the create, not a later start.
            try await self.networksService?.reserveAddresses(for: configuration.id, attachments: configuration.networks)
            do {
                return try await Self.withNewContainerDirectory(at: path) {
                    self.log.debug(
                        "create snapshot",
                        metadata: [
                            "id": "\(configuration.id)",
                            "ref": "\(configuration.image.reference)",
                        ])
                    let containerImage = ClientImage(description: configuration.image)
                    let imageFs = try await options.rootFsOverride == nil ? containerImage.getCreateSnapshot(platform: configuration.platform) : nil

                    self.log.debug(
                        "configure runtime",
                        metadata: [
                            "id": "\(configuration.id)",
                            "kernel": "\(kernel.path)",
                            "initfs": "\(initImage ?? self.containerSystemConfig.vminit.image)",
                        ])
                    let runtimeConfig = RuntimeConfiguration(
                        path: path,
                        initialFilesystem: initFilesystem,
                        kernel: kernel,
                        containerConfiguration: configuration,
                        containerRootFilesystem: imageFs,
                        options: options,
                        runtimeData: runtimeData
                    )

                    try runtimeConfig.writeRuntimeConfiguration()
                    let incarnation = requestedIncarnation ?? UUID().uuidString.lowercased()
                    try Self.persistIncarnation(incarnation, at: path)
                    try Self.persistHostDirectoryBookmarks(requiredHostDirectoryBookmarks, at: path)
                    // A record from the start, so that only bundles older than it are read
                    // as legacy ones.
                    try ContainerResource.Bundle(path: path).setRestartRecord(RestartRecord())

                    let snapshot = ContainerSnapshot(
                        configuration: configuration,
                        incarnation: incarnation,
                        status: .stopped,
                        networks: [],
                        startedDate: nil
                    )
                    guard
                        await self.hostDirectoryAccess.resolve(
                            bookmarks: requiredHostDirectoryBookmarks,
                            for: configuration.id)
                    else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "failed to resolve host-directory authorization for container \(configuration.id)"
                        )
                    }
                    await self.setContainerState(configuration.id, ContainerState(snapshot: snapshot), context: context)
                    return incarnation
                }
            } catch {
                await self.networksService?.releaseAddresses(for: configuration.id)
                throw error
            }
        }
    }

    /// Hold an address for every container that exists, once the networks are up. The
    /// helpers start empty with the engine, so the reservations made at create are made
    /// again here; in id order, so the outcome does not depend on dictionary order.
    public func reserveAddressesForExistingContainers() async {
        for id in containers.keys.sorted() {
            guard let configuration = containers[id]?.snapshot.configuration else { continue }
            do {
                try await networksService?.reserveAddresses(for: id, attachments: configuration.networks)
            } catch {
                log.warning("could not reserve addresses", metadata: ["id": "\(id)", "error": "\(error)"])
            }
        }
    }

    /// Bootstrap the init process of the container.
    ///
    /// - Parameter hostDirectoryBookmarks: fresh bind-mount grants from the embedder, if it has
    ///   any. A start after the machine restarted has no other source of them.
    public func bootstrap(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String],
        hostDirectoryBookmarks: [Data] = []
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "env": "\(dynamicEnv)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self.getContainerState(id: id, context: context)
            if state.client != nil {
                return
            }
            // A start by hand, which is where Docker starts the restart bookkeeping over:
            // the person's stop no longer holds, the count and the delays begin again, and a
            // restart that was waiting is this start now.
            state.cancelPendingRestart()
            if state.snapshot.status == .restarting {
                state.snapshot.status = .stopped
            }
            state.restartRecord.stoppedByUser = false
            state.restartRecord.restartCount = 0
            state.backoff.reset()
            state.snapshot.restartCount = 0
            state.snapshot.restartError = nil
            state.dynamicEnv = dynamicEnv
            await self.setContainerState(id, state, context: context)
            await self.persistRestartRecord(state.restartRecord, for: id)

            try await self.bootstrapLocked(
                id: id,
                stdio: stdio,
                dynamicEnv: dynamicEnv,
                hostDirectoryBookmarks: hostDirectoryBookmarks,
                askEmbedder: true,
                context: context)
        }
    }

    /// Bootstrap under the lock. `askEmbedder` is false for the engine's own starts, which
    /// never put a folder panel in front of the user: a folder nothing grants fails them.
    private func bootstrapLocked(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String],
        hostDirectoryBookmarks: [Data],
        askEmbedder: Bool,
        context: AsyncLock.Context
    ) async throws {
        var state = try self.getContainerState(id: id, context: context)

        // We've already bootstrapped this container. Ideally we should be able to
        // return some sort of error code from the sandbox svc to check here, but this
        // is also a very simple check and faster than doing an rpc to get the same result.
        if state.client != nil {
            return
        }

        let path = self.containerRoot.appendingPathComponent(id)
        let (config, _) = try Self.getContainerConfiguration(at: path)
        if let held = Self.volumeInUse(by: self.containers.values.map(\.snapshot), neededBy: config) {
            throw ContainerizationError(
                .invalidState,
                message:
                    "volume \(held.volume) is in use by container \(held.container): a volume is a disk, and one running container holds it at a time. Stop \(held.container) first, or give this container a volume of its own"
            )
        }
        try await self.restoreHostDirectoryAccess(
            for: id, configuration: config, at: path, supplied: hostDirectoryBookmarks, askEmbedder: askEmbedder)

        var networkBootstrapInfos = [NetworkBootstrapInfo]()
        for n in config.networks {
            guard let plugin = try await self.networksService?.plugin(for: n.network) else {
                throw ContainerizationError(.internalError, message: "failed to get plugin for network \(n.network)")
            }
            networkBootstrapInfos.append(NetworkBootstrapInfo(plugin: plugin))
        }

        do {
            try Self.registerService(
                plugin: self.runtimePlugins.first { $0.name == config.runtimeHandler }!,
                loader: self.pluginLoader,
                configuration: config,
                path: path,
                debug: self.debugHelpers
            )

            let runtime = state.snapshot.configuration.runtimeHandler
            // RuntimeClient.create resolves a brokered endpoint when the
            // instance was spawned (sandboxed embedding), else dials the
            // instance's mach service as upstream does.
            let runtimeClient = try await RuntimeClient.create(id: id, runtime: runtime)
            try await runtimeClient.bootstrap(stdio: stdio, networkBootstrapInfos: networkBootstrapInfos, dynamicEnv: dynamicEnv)

            let incarnation = state.snapshot.incarnation
            let run = UUID()
            try await self.exitMonitor.registerProcess(
                id: id,
                onOutcome: { [self] exitedID, outcome in
                    switch outcome {
                    case .exited(let code):
                        try await handleContainerExit(
                            id: exitedID, code: code, expectedIncarnation: incarnation, expectedRun: run)
                    case .waitFailed:
                        // Recorded as -1, as it always was; but how the process ended is not
                        // known, and the restart policy is told so.
                        try await handleContainerExit(
                            id: exitedID, code: ExitStatus(exitCode: -1), waitFailed: true,
                            expectedIncarnation: incarnation, expectedRun: run)
                    }
                }
            )

            state.client = runtimeClient
            state.run = run
            state.exitRequested = false
            await self.setContainerState(id, state, context: context)
        } catch {
            let label = try? self.pluginLoader.fullLaunchdLabel(
                pluginName: config.runtimeHandler,
                instanceId: id
            )

            await self.exitMonitor.stopTracking(id: id)
            if let label {
                try? ServiceManager.deregister(fullServiceLabel: label)
            }
            throw error
        }
    }

    /// Create a new process in the container.
    public func createProcess(
        id: String,
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "command": "\(config.arguments.isEmpty ? "" : config.arguments[0])",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.createProcess(
            processID,
            config: config,
            stdio: stdio
        )
    }

    /// Start a process in a container. This can either be a process created via
    /// createProcess, or the init process of the container which requires
    /// id == processID.
    public func startProcess(id: String, processID: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)", "processId": "\(processID)"]) { context in
            try await self.startProcessLocked(id: id, processID: processID, context: context)
        }
        // As Docker's resolver does: by the time a start returns, its peers know the name.
        if Self.isInitProcess(id: id, processID: processID) {
            await self.settlePeerHosts()
        }
    }

    private func startProcessLocked(id: String, processID: String, context: AsyncLock.Context) async throws {
        var state = try self.getContainerState(id: id, context: context)

        let isInit = Self.isInitProcess(id: id, processID: processID)
        if state.snapshot.status == .running && isInit {
            return
        }

        let client = try state.getClient()
        try await client.startProcess(processID)

        guard isInit else {
            return
        }

        do {
            let log = self.log
            let waitFunc: ExitMonitor.WaitHandler = {
                log.info("registering container with exit monitor")
                let code = try await client.wait(id)
                log.info(
                    "container finished in exit monitor",
                    metadata: [
                        "id": "\(id)",
                        "rc": "\(code)",
                    ])

                return code
            }
            try await self.exitMonitor.track(id: id, waitingOn: waitFunc)

            let sandboxSnapshot = try await client.state()
            state.snapshot.status = .running
            state.snapshot.networks = sandboxSnapshot.networks
            state.snapshot.startedDate = Date()
            state.snapshot.restartError = nil
            // The runtime checks the container's health from now on; this side follows it.
            if state.snapshot.configuration.healthCheck != nil, let run = state.run {
                let earlierLog = state.snapshot.health?.log ?? []
                state.snapshot.health = HealthWatch.starting(after: state.snapshot.health)
                state.healthWatch?.cancel()
                state.healthWatch = self.watchHealth(
                    id: id, incarnation: state.snapshot.incarnation, run: run, client: client, earlierLog: earlierLog)
            }
            let firstStart = !state.restartRecord.hasBeenStarted
            state.restartRecord.hasBeenStarted = true
            await self.setContainerState(id, state, context: context)
            if firstStart {
                await self.persistRestartRecord(state.restartRecord, for: id)
            }
        } catch {
            await self.exitMonitor.stopTracking(id: id)
            try? await client.stop(options: ContainerStopOptions.default)
            throw error
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, processID: String, signal: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "signal": "\(signal)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        var state = try self._getContainerState(id: id)
        if processID == id, let parsed = try? Signal(signal) {
            // A signal to the container's own process is a person acting on the container,
            // which Docker counts as their stop for the restart policy — marked before the
            // signal is sent, because the exit it causes can be handled before this returns.
            let observed = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                try await self.markStopRequested(id: id, byUser: true, signal: parsed, context: context)
            }
            guard let observed else { return }
            state = observed
        }
        let client = try state.getClient()
        try await client.kill(processID, signal: signal)

        // SIGKILL is guaranteed to terminate the target. When directed at the
        // container's init process, follow up with the same API-server cleanup
        // that `stop` performs. The captured incarnation keeps an old kill completion from
        // stopping a replacement that reused the ID, and the captured run one from ending
        // a restart of this one.
        if processID == id, (try? Signal(signal)) == .kill, let run = state.run {
            try await handleContainerExit(
                id: id, expectedIncarnation: state.snapshot.incarnation, expectedRun: run)
            await self.settlePeerHosts()
        }
    }

    /// Record, before a stop or a kill is sent, that this run was asked to end, and whether a
    /// person asked. Returns the state to act on, or nil when the request is done with: a
    /// container waiting out a restart delay is stopped right here, by ending the wait.
    ///
    /// - Parameters:
    ///   - byUser: the request is a person's, not the engine going down.
    ///   - signal: for a kill, the signal sent. Only SIGKILL, the container's stop signal,
    ///     or any signal for a container without one ends its restarts; any signal counts
    ///     as a person's stop. A stop always ends them.
    private func markStopRequested(
        id: String,
        byUser: Bool,
        signal: Signal? = nil,
        context: AsyncLock.Context
    ) async throws -> ContainerState? {
        var state = try self.getContainerState(id: id, context: context)
        let waiting = state.client == nil && state.snapshot.status == .restarting
        // A container that is not running and not about to be is left as it is.
        guard state.client != nil || waiting else { return state }

        let ends = signal.map { RestartRules.signalEndsRestarts($0, stopSignal: state.snapshot.configuration.stopSignal) } ?? true
        if byUser && !self.engineShuttingDown && !state.restartRecord.stoppedByUser {
            state.restartRecord.stoppedByUser = true
            await self.persistRestartRecord(state.restartRecord, for: id)
        }
        guard waiting else {
            if ends {
                state.exitRequested = true
            }
            await self.setContainerState(id, state, context: context)
            return state
        }
        guard ends else {
            await self.setContainerState(id, state, context: context)
            return nil
        }
        state.cancelPendingRestart()
        state.snapshot.status = .stopped
        await self.setContainerState(id, state, context: context)
        self.log.info("restart cancelled by a stop", metadata: ["id": "\(id)"])
        if (try? self.getContainerCreationOptions(id: id))?.autoRemove == true {
            try await self.cleanUp(id: id, context: context)
        }
        return nil
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(
        id: String,
        options: ContainerStopOptions,
        responseTimeout: Duration? = nil,
        requiredLabels: [String: String]? = nil,
        expectedIncarnation: String? = nil
    ) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let clock = ContinuousClock()
        let responseDeadline = responseTimeout.map { clock.now.advanced(by: $0) }
        let observed = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)-precondition", "id": "\(id)"]
        ) { context in
            let state = try await self.getContainerState(id: id, context: context)
            try Self.require(
                labels: requiredLabels,
                incarnation: expectedIncarnation,
                on: state,
                id: id)
            // Before the stop is sent: the exit it causes is usually handled first, and must
            // already know that it was asked for, and by whom.
            return try await self.markStopRequested(id: id, byUser: !options.engineShutdown, context: context)
        }
        // From here the stop goes through this state's own runtime client, not through the
        // ID again, so what is stopped is what was just checked. Post-stop cleanup carries
        // this state's generated incarnation and refuses a same-ID replacement.

        // Stop should be idempotent.
        guard let state = observed, let run = state.run else {
            return
        }
        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            return
        }

        var resolvedOptions = options
        if resolvedOptions.signal == nil, let stopSignal = state.snapshot.configuration.stopSignal {
            resolvedOptions.signal = stopSignal
        }

        do {
            try await client.stop(options: resolvedOptions, responseTimeout: responseTimeout)
        } catch let err as ContainerizationError {
            if err.code != .interrupted {
                throw err
            }
        }
        let remainingResponseTimeout = responseDeadline.map {
            max(Duration.zero, clock.now.duration(to: $0))
        }
        try await handleContainerExit(
            id: id,
            code: nil,
            responseTimeout: remainingResponseTimeout,
            expectedIncarnation: state.snapshot.incarnation,
            expectedRun: run
        )
        // And by the time a stop returns, its peers no longer list it.
        await self.settlePeerHosts()
    }

    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "port": "\(port)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "port": "\(port)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.dial(port)
    }

    /// Wait waits for the container's init process or exec to exit and returns the
    /// exit status.
    public func wait(id: String, processID: String) async throws -> ExitStatus {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.wait(processID)
    }

    /// Resize resizes the container's PTY if one exists.
    public func resize(id: String, processID: String, size: Terminal.Size) async throws {
        log.trace(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.trace(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.resize(processID, size: size)
    }

    // Get the logs for the container.
    public func logs(id: String) async throws -> [FileHandle] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Logs doesn't care if the container is running or not, just that
        // the bundle is there, and that the files actually exist. We do
        // first try and get the container state so we get a nicer error message
        // (container foo not found) however.
        do {
            _ = try _getContainerState(id: id)
            let path = self.containerRoot.appendingPathComponent(id)
            let bundle = ContainerResource.Bundle(path: path)
            return [
                try FileHandle(forReadingFrom: bundle.containerLog),
                try FileHandle(forReadingFrom: bundle.bootlog),
            ]
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container logs: \(error)"
            )
        }
    }

    /// Copy a file or directory from the host into the container.
    public func copyIn(id: String, source: String, destination: String, mode: UInt32, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        let bookmark = try await Self.copyHostDirectoryBookmark(for: source, verb: "read")
        try await client.copyIn(source: source, destination: destination, mode: mode, createParents: createParents, hostDirectoryBookmark: bookmark)
    }

    /// Copy a file or directory from the container to the host.
    public func copyOut(id: String, source: String, destination: String, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        let bookmark = try await Self.copyHostDirectoryBookmark(for: destination, verb: "write")
        try await client.copyOut(source: source, destination: destination, createParents: createParents, hostDirectoryBookmark: bookmark)
    }

    /// Copy runs in an existing helper, which cannot inherit access acquired after it was
    /// spawned. Forward the app's original bookmark, not one minted from borrowed access.
    /// This also covers SDK callers that do not go through the CLI's metadata checks.
    static func copyHostDirectoryBookmark(
        for path: String, verb: String,
        sandboxed: Bool = ServiceIdentity.appGroup != nil,
        lend: @Sendable (String) async -> (bookmark: Data?, outcome: HostDirectoryGrants.GrantOutcome) = { await HostDirectoryGrants.shared.lend($0) }
    ) async throws -> Data? {
        try Task.checkCancellation()
        guard sandboxed else { return nil }
        let folder = HostPath.folderForCopy(for: path)
        let (bookmark, outcome) = await lend(folder)
        try Task.checkCancellation()
        guard case .granted = outcome, let bookmark else {
            let reason = HostDirectoryGrantHarness.wire(outcome)
            throw ContainerizationError(
                .invalidArgument,
                message: (reason == .granted ? HostDirectoryLendOutcome.declined : reason).message(for: folder, verb: verb))
        }
        return bookmark
    }

    /// Get statistics for the container.
    public func stats(id: String) async throws -> ContainerStats {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.statistics()
    }

    /// Whether `state` carries every label in `required`. Labels express ownership policy;
    /// they deliberately do not identify one creation of an ID.
    static func labelsSatisfied(required: [String: String]?, actual: [String: String]) -> Bool {
        guard let required else { return true }
        return required.allSatisfy { actual[$0.key] == $0.value }
    }

    /// Exact-object precondition used by destructive operations and exit processing.
    static func incarnationSatisfied(expected: String?, actual: String) -> Bool {
        guard let expected else { return true }
        return !expected.isEmpty && expected == actual
    }

    /// The second check, under the lock and against the table as it is now.
    private func requireStillCurrent(
        id: String,
        labels: [String: String]?,
        incarnation: String?
    ) throws {
        try Self.require(
            labels: labels,
            incarnation: incarnation,
            on: try self._getContainerState(id: id),
            id: id)
    }

    private static func require(
        labels: [String: String]?,
        incarnation: String?,
        on state: ContainerState,
        id: String
    ) throws {
        guard labelsSatisfied(required: labels, actual: state.snapshot.configuration.labels) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container \(id) does not carry the labels this operation requires")
        }
        guard incarnationSatisfied(expected: incarnation, actual: state.snapshot.incarnation) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container \(id) is not the incarnation this operation observed")
        }
    }

    /// Delete a container and its resources.
    ///
    /// Ownership labels and exact incarnation are checked up front and under the lock
    /// immediately before removal.
    public func delete(
        id: String,
        force: Bool,
        requiredLabels: [String: String]? = nil,
        expectedIncarnation: String? = nil
    ) async throws {
        log.info(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "force": "\(force)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)-precondition", "id": "\(id)"]
        ) { context in
            var state = try await self.getContainerState(id: id, context: context)
            try Self.require(
                labels: requiredLabels,
                incarnation: expectedIncarnation,
                on: state,
                id: id)
            if force, state.snapshot.status == .running || state.snapshot.status == .restarting {
                // Gone either way: the exit the kill below causes must not start it again.
                state.exitRequested = true
                state.cancelPendingRestart()
                await self.setContainerState(id, state, context: context)
            }
            return state
        }
        switch state.snapshot.status {
        case .running:
            if !force {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and can not be deleted"
                )
            }
            let opts = ContainerStopOptions(
                timeoutInSeconds: 5,
                signal: "SIGKILL"
            )
            let client = try state.getClient()
            try await client.stop(options: opts)
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                self.log.info(
                    "ContainersService: attempt cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                try await self.requireStillCurrent(
                    id: id,
                    labels: requiredLabels,
                    incarnation: state.snapshot.incarnation)
                try await self.cleanUp(id: id, context: context)
                self.log.info(
                    "ContainersService: successful cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
            }
        case .restarting where !force:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is restarting and can not be deleted: stop it first, or delete it with force"
            )
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is \(state.snapshot.status) and can not be deleted"
            )
        default:
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                try await self.requireStillCurrent(
                    id: id,
                    labels: requiredLabels,
                    incarnation: state.snapshot.incarnation)
                try await self.cleanUp(id: id, context: context)
            }
        }
        await self.settlePeerHosts()
    }

    public func containerDiskUsage(id: String) async throws -> UInt64 {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let containerPath = self.containerRoot.appendingPathComponent(id).path

        return FileManager.default.allocatedSize(of: URL(fileURLWithPath: containerPath))
    }

    public func exportRootfs(id: String, archive: URL) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let rootfs = bundle.containerRootfsBlock

        switch state.snapshot.status {
        case .running:
            let client = try state.getClient()
            let snapshot = rootfs.appendingPathExtension("snapshot")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try await client.snapshotDisk(imagePath: rootfs.path, destinationPath: snapshot.path)
            try EXT4.EXT4Reader(blockDevice: FilePath(snapshot)).export(archive: FilePath(archive))
        case .stopped:
            try EXT4.EXT4Reader(blockDevice: FilePath(rootfs)).export(archive: FilePath(archive))
        default:
            throw ContainerizationError(.invalidState, message: "container must be running or stopped")
        }
    }

    public func clean(id: String) async throws {
        self.log.debug("\(#function)")

        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container is not running")
        }

        let client = try state.getClient()
        try await client.clean(id: id)
    }

    private func handleContainerExit(
        id: String,
        code: ExitStatus? = nil,
        waitFailed: Bool = false,
        expectedIncarnation: String,
        expectedRun: UUID
    ) async throws {
        try await handleContainerExit(
            id: id,
            code: code,
            waitFailed: waitFailed,
            responseTimeout: nil,
            expectedIncarnation: expectedIncarnation,
            expectedRun: expectedRun)
    }

    private func handleContainerExit(
        id: String,
        code: ExitStatus?,
        waitFailed: Bool = false,
        responseTimeout: Duration?,
        expectedIncarnation: String,
        expectedRun: UUID
    ) async throws {
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { [self] context in
            try await handleContainerExit(
                id: id,
                code: code,
                waitFailed: waitFailed,
                responseTimeout: responseTimeout,
                expectedIncarnation: expectedIncarnation,
                expectedRun: expectedRun,
                context: context
            )
        }
    }

    /// - Parameters:
    ///   - code: the exit the runtime reported; nil when a stop or a kill ended the run and
    ///     nothing was reported.
    ///   - waitFailed: the wait on the runtime failed, and `code` is a stand-in.
    ///   - expectedRun: the run this exit is for; an exit of an earlier run is ignored.
    private func handleContainerExit(
        id: String,
        code: ExitStatus?,
        waitFailed: Bool,
        responseTimeout: Duration?,
        expectedIncarnation: String,
        expectedRun: UUID,
        context: AsyncLock.Context
    ) async throws {
        if let code {
            self.log.info(
                "handling container exit",
                metadata: [
                    "id": "\(id)",
                    "rc": "\(code)",
                ])
        }

        var state: ContainerState
        do {
            state = try self.getContainerState(id: id, context: context)
            // Exit callbacks and explicit stop completions are tied to the runtime they
            // observed. A replacement can reuse the ID while either awaits, but it must not
            // be stopped, deregistered, or auto-removed by the predecessor's completion.
            guard state.snapshot.incarnation == expectedIncarnation else { return }
            // The same holds within one incarnation: once the run this was for has been torn
            // down, a later run of the container, or a restart waiting to make one, is not
            // this exit's to end.
            guard state.run == expectedRun else { return }
            if state.snapshot.status == .stopped {
                return
            }
        } catch {
            // Was auto removed by the background thread, nothing for us to do.
            return
        }

        try await self.tearDownRuntime(id: id, client: state.client, responseTimeout: responseTimeout)

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        state.snapshot.networks = []
        // Keep why it stopped, not just that it did — in memory for this apiserver, and
        // on disk so the answer survives a restart.
        if let code {
            state.snapshot.exitCode = code.exitCode
            state.snapshot.exitedAt = code.exitedAt
            do {
                try bundle.setExitStatus(
                    ExitRecord(exitCode: code.exitCode, exitedAt: code.exitedAt))
            } catch {
                self.log.warning(
                    "failed to record exit status",
                    metadata: ["id": "\(id)", "error": "\(error)"])
            }
        }
        state.client = nil
        state.run = nil
        state.endHealthWatch()

        // Decided before auto-remove, which applies only to a container that stays stopped.
        let end: ContainerRunEnd = waitFailed ? .lost : code.map { .exited($0.exitCode) } ?? .stopped
        let restarts = RestartRules.restartsAfterExit(
            policy: state.snapshot.configuration.restartPolicy,
            end: end,
            exitRequested: state.exitRequested,
            stoppedByUser: state.restartRecord.stoppedByUser,
            engineShuttingDown: self.engineShuttingDown,
            restartCount: state.restartRecord.restartCount)
        state.exitRequested = false
        if restarts {
            let ranFor = state.snapshot.startedDate.map { Duration.seconds(max(0, (code?.exitedAt ?? Date()).timeIntervalSince($0))) } ?? .zero
            let delay = state.backoff.next(ranFor: ranFor)
            state.restartRecord.restartCount += 1
            state.snapshot.restartCount = state.restartRecord.restartCount
            state.snapshot.status = .restarting
            self.scheduleRestart(of: id, after: delay, in: &state)
            await self.setContainerState(id, state, context: context)
            await self.persistRestartRecord(state.restartRecord, for: id)
            self.log.info(
                "restarting container",
                metadata: [
                    "id": "\(id)",
                    "restartCount": "\(state.restartRecord.restartCount)",
                    "delay": "\(delay)",
                ])
            return
        }

        state.snapshot.status = .stopped
        await self.setContainerState(id, state, context: context)

        let options = try getContainerCreationOptions(id: id)
        if options.autoRemove {
            try await self.cleanUp(id: id, context: context)
        }
    }

    /// Stop watching a run, and shut down and deregister its runtime helper.
    private func tearDownRuntime(id: String, client: RuntimeClient?, responseTimeout: Duration?) async throws {
        await self.exitMonitor.stopTracking(id: id)

        // Shutdown and deregister the runtime service
        self.log.info("shutting down runtime service", metadata: ["id": "\(id)"])

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let label = try self.pluginLoader.fullLaunchdLabel(
            pluginName: config.runtimeHandler,
            instanceId: id
        )

        // Try to shutdown the client gracefully, but if the runtime service
        // is already dead (e.g., killed externally), we should still continue
        // with state cleanup.
        if let client {
            do {
                try await client.shutdown(responseTimeout: responseTimeout)
            } catch {
                self.log.error(
                    "failed to shutdown runtime service",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ])
            }
        }

        // Deregister the service, launchd will terminate the process.
        // This may also fail if the service was already deregistered or
        // the process was killed externally.
        do {
            try ServiceManager.deregister(fullServiceLabel: label)
            self.log.info("deregistered runtime service", metadata: ["id": "\(id)"])
        } catch {
            self.log.error(
                "failed to deregister runtime service",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }
    }

    // MARK: Health checks

    /// Follow the health check the runtime runs for this run of the container, keeping the
    /// snapshot's health current until the run ends.
    private func watchHealth(
        id: String, incarnation: String, run: UUID, client: RuntimeClient, earlierLog: [HealthCheckResult]
    ) -> Task<Void, Never> {
        // Holds the service only as long as the run it follows: the wait fails when the
        // run's helper goes away, and the task is cancelled when the run ends.
        Task {
            await HealthWatch.follow(
                wait: { try await client.waitHealth(after: $0) },
                apply: { update in
                    await self.applyHealth(update, id: id, incarnation: incarnation, run: run, earlierLog: earlierLog)
                })
        }
    }

    /// Take a health update for a run, if that run is still the container's and still
    /// running. Under the lock, so that an operation that read the state before it cannot
    /// write the old health back. Returns whether the run is still worth following.
    private func applyHealth(
        _ update: HealthUpdate, id: String, incarnation: String, run: UUID, earlierLog: [HealthCheckResult]
    ) async -> Bool {
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { _ in
            await self.setHealth(update, id: id, incarnation: incarnation, run: run, earlierLog: earlierLog)
        }
    }

    private func setHealth(
        _ update: HealthUpdate, id: String, incarnation: String, run: UUID, earlierLog: [HealthCheckResult]
    ) -> Bool {
        guard var state = self.containers[id] else { return false }
        let before = state.snapshot.health?.status
        guard
            HealthWatch.apply(
                update, to: &state.snapshot, currentRun: state.run, run: run, incarnation: incarnation, earlierLog: earlierLog)
        else { return false }
        if let after = state.snapshot.health?.status, after != before {
            self.log.info("health status changed", metadata: ["id": "\(id)", "status": "\(after.rawValue)"])
        }
        self.containers[id]?.snapshot.health = state.snapshot.health
        return true
    }

    // MARK: Restart policies

    /// Start the container again once `delay` has passed, unless something ends the wait
    /// first: a stop, a start by hand, a delete, or the engine going down.
    private func scheduleRestart(of id: String, after delay: Duration, in state: inout ContainerState) {
        let token = UUID()
        let incarnation = state.snapshot.incarnation
        let wait = self.restartDelay
        state.cancelPendingRestart()
        state.pendingRestart = token
        state.pendingRestartTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            await self?.restartAfterDelay(id: id, incarnation: incarnation, token: token)
        }
    }

    private func restartAfterDelay(id: String, incarnation: String, token: UUID) async {
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            guard var state = try? await self.getContainerState(id: id, context: context),
                state.snapshot.incarnation == incarnation,
                state.snapshot.status == .restarting,
                state.pendingRestart == token,
                !(await self.engineShuttingDown)
            else { return }
            state.pendingRestart = nil
            state.pendingRestartTask = nil
            await self.setContainerState(id, state, context: context)
            do {
                try await self.startByEngine(id: id, dynamicEnv: state.dynamicEnv, context: context)
            } catch {
                await self.engineStartFailed(id: id, error: error, context: context)
            }
        }
    }

    /// Start a container the engine decided to start, under the lock: detached, with what it
    /// already holds for its folders, and without asking anyone for more.
    private func startByEngine(id: String, dynamicEnv: [String: String], context: AsyncLock.Context) async throws {
        try await self.bootstrapLocked(
            id: id,
            stdio: [nil, nil, nil],
            dynamicEnv: dynamicEnv,
            hostDirectoryBookmarks: [],
            askEmbedder: false,
            context: context)
        try await self.startProcessLocked(id: id, processID: id, context: context)
    }

    /// An engine-made start did not work: the container stays stopped with the reason, as
    /// Docker leaves one whose restart fails, and auto-remove applies to it as to any
    /// container that stops.
    private func engineStartFailed(id: String, error: any Error, context: AsyncLock.Context) async {
        guard var state = try? self.getContainerState(id: id, context: context) else { return }
        self.log.error(
            "engine could not start container",
            metadata: ["id": "\(id)", "error": "\(error)"])
        if state.client != nil {
            try? await self.tearDownRuntime(id: id, client: state.client, responseTimeout: nil)
        }
        state.client = nil
        state.run = nil
        state.exitRequested = false
        state.endHealthWatch()
        state.snapshot.status = .stopped
        state.snapshot.networks = []
        state.snapshot.restartError = String(describing: error)
        await self.setContainerState(id, state, context: context)
        if (try? self.getContainerCreationOptions(id: id))?.autoRemove == true {
            try? await self.cleanUp(id: id, context: context)
        }
    }

    /// From here on the engine is going down: no run that ends is started again, no stop is a
    /// person's, and the restarts waiting out their delay are dropped. The containers they
    /// were for keep their claim to start with the engine next time.
    public func beginEngineShutdown() async {
        self.engineShuttingDown = true
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { context in
            for (id, var state) in await self.containers where state.snapshot.status == .restarting && state.client == nil {
                state.cancelPendingRestart()
                state.snapshot.status = .stopped
                await self.setContainerState(id, state, context: context)
            }
        }
    }

    /// Start, once the engine is up and its networks are, the containers whose restart policy
    /// says they start with the engine: `always` ones that have been started before, and
    /// `unless-stopped` ones that a person did not stop. As at a start by hand, the count of
    /// restarts begins again.
    ///
    /// A container whose folders nothing grants yet is tried again once the embedding app has
    /// had time to publish its grants, which it does a moment after it sees the engine; one
    /// that still cannot start stays stopped with the reason.
    public func startContainersWithEngine(grantWait: Duration = .seconds(30)) async {
        let candidates = self.containers.values
            .filter {
                $0.snapshot.status == .stopped
                    && RestartRules.startsWithEngine(policy: $0.snapshot.configuration.restartPolicy, record: $0.restartRecord)
            }
            .map(\.snapshot.id)
            .sorted()
        guard !candidates.isEmpty else { return }
        self.log.info("starting containers with the engine", metadata: ["count": "\(candidates.count)"])

        var awaitingGrants: [String: Set<String>] = [:]
        for id in candidates {
            if let sources = await self.startWithEngine(id: id, deferUngranted: true) {
                awaitingGrants[id] = sources
            }
        }
        guard !awaitingGrants.isEmpty else { return }

        let deadline = ContinuousClock.now.advanced(by: grantWait)
        let sources = awaitingGrants.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        while ContinuousClock.now < deadline {
            var covered = true
            for source in sources where !(await HostDirectoryGrants.shared.covers(source)) {
                covered = false
            }
            if covered { break }
            do {
                try await self.restartDelay(.milliseconds(250))
            } catch {
                break
            }
        }
        for id in awaitingGrants.keys.sorted() {
            _ = await self.startWithEngine(id: id, deferUngranted: false)
        }
    }

    /// One start at engine start. Returns the folders to wait for when `deferUngranted` and
    /// the start failed for want of a grant; nil otherwise.
    private func startWithEngine(id: String, deferUngranted: Bool) async -> Set<String>? {
        await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            guard var state = try? await self.getContainerState(id: id, context: context),
                state.snapshot.status == .stopped, state.client == nil,
                !(await self.engineShuttingDown)
            else { return nil }
            state.restartRecord.stoppedByUser = false
            state.restartRecord.restartCount = 0
            state.backoff.reset()
            state.snapshot.restartCount = 0
            state.snapshot.restartError = nil
            await self.setContainerState(id, state, context: context)
            await self.persistRestartRecord(state.restartRecord, for: id)
            do {
                try await self.startByEngine(id: id, dynamicEnv: [:], context: context)
                self.log.info("started container with the engine", metadata: ["id": "\(id)"])
                return nil
            } catch let ungranted as HostDirectoryNotGranted where deferUngranted {
                await self.engineStartFailed(id: id, error: ungranted, context: context)
                return Set(state.snapshot.configuration.mounts.filter(\.isVirtiofs).map(\.source))
            } catch {
                await self.engineStartFailed(id: id, error: error, context: context)
                return nil
            }
        }
    }

    private func persistRestartRecord(_ record: RestartRecord, for id: String) async {
        let bundle = ContainerResource.Bundle(path: self.containerRoot.appendingPathComponent(id))
        do {
            try bundle.setRestartRecord(record)
        } catch {
            self.log.warning(
                "failed to record restart state",
                metadata: ["id": "\(id)", "error": "\(error)"])
        }
    }

    private func _cleanUp(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Give back any host-directory grants this container was holding. Before the early
        // return below: a container the exit handler already reaped still resolved bookmarks
        // at create, and nothing else would ever hand them back.
        await self.hostDirectoryAccess.release(for: id)
        // And the addresses held for it since create: the container is going away.
        await self.networksService?.releaseAddresses(for: id)

        // Did the exit container handler win?
        if self.containers[id] == nil {
            return
        }
        // A restart waiting out its delay is for a container that is going away, and so is
        // the health check it was following.
        self.containers[id]?.cancelPendingRestart()
        self.containers[id]?.endHealthWatch()

        // To be pedantic. This is only needed if something in the "launch
        // the init process" lifecycle fails before actually fork+exec'ing
        // the OCI runtime.
        await self.exitMonitor.stopTracking(id: id)
        let path = self.containerRoot.appendingPathComponent(id)

        // Try to get config for service deregistration
        // Don't fail if bundle is incomplete
        var config: ContainerConfiguration?
        let bundle = ContainerResource.Bundle(path: path)
        do {
            config = try bundle.configuration
        } catch {
            self.log.warning(
                "failed to read bundle configuration during cleanup for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        // Only try to deregister service if we have a valid config
        // TODO: Change this so we don't have to reread the config
        // possibly store the container ID to service label mapping
        if let config = config,
            let label = try? self.pluginLoader.fullLaunchdLabel(
                pluginName: config.runtimeHandler,
                instanceId: id
            )
        {
            try? ServiceManager.deregister(fullServiceLabel: label)
        }

        // Remove the persisted capability separately so a later bundle-delete failure cannot
        // leave authorization behind after this container is forgotten.
        try Self.removePersistedHostDirectoryBookmarks(at: path)

        // Always try to delete the bundle directory, even if it's incomplete.
        do {
            try bundle.delete()
        } catch {
            self.log.warning(
                "failed to delete bundle for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        let removed = self.containers.removeValue(forKey: id)
        await self.peerMembershipChanged(old: removed?.snapshot, new: nil)
    }

    private func cleanUp(id: String, context: AsyncLock.Context) async throws {
        try await self._cleanUp(id: id)
    }

    private static func persistIncarnation(_ incarnation: String, at path: URL) throws {
        let destination = path.appendingPathComponent(Self.incarnationFilename)
        try Data(incarnation.utf8).write(to: destination, options: .atomic)
    }

    /// Reserve the directory exclusively after asynchronous preparation. A bundle
    /// restored since create's initial existence check must never enter its rollback.
    /// A volume `configuration` mounts that another container has attached, with that
    /// container. A volume is a disk image, and Virtualization refuses a machine whose
    /// disk another machine has open, with an error that names neither.
    static func volumeInUse(
        by containers: [ContainerSnapshot], neededBy configuration: ContainerConfiguration
    ) -> (volume: String, container: String)? {
        let needed = Set(configuration.mounts.compactMap(\.volumeName))
        guard !needed.isEmpty else { return nil }
        for container in containers.sorted(by: { $0.id < $1.id }) where container.id != configuration.id && container.status != .stopped {
            if let volume = container.configuration.mounts.compactMap(\.volumeName).first(where: needed.contains) {
                return (volume, container.id)
            }
        }
        return nil
    }

    static func withNewContainerDirectory<T: Sendable>(
        at path: URL, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        do {
            return try await body()
        } catch {
            try? FileManager.default.removeItem(at: path)
            throw error
        }
    }

    static func loadOrCreateIncarnation(at path: URL) throws -> String {
        let source = path.appendingPathComponent(Self.incarnationFilename)
        if let data = try? Data(contentsOf: source),
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            UUID(uuidString: value) != nil
        {
            return value.lowercased()
        }
        // Migration for bundles created before incarnation preconditions existed. The token
        // is generated by the engine and persisted outside configuration, so labels cannot
        // forge it and the same container keeps its identity across API-server restarts.
        let value = UUID().uuidString.lowercased()
        try persistIncarnation(value, at: path)
        return value
    }

    private static func persistHostDirectoryBookmarks(_ bookmarks: [Data], at path: URL) throws {
        let data = try JSONEncoder().encode(bookmarks)
        let destination = path.appendingPathComponent(Self.hostDirectoryBookmarksFilename)
        try data.write(to: destination, options: .atomic)
    }

    private static func removePersistedHostDirectoryBookmarks(at path: URL) throws {
        let bookmarksPath = path.appendingPathComponent(Self.hostDirectoryBookmarksFilename)
        guard FileManager.default.fileExists(atPath: bookmarksPath.path) else { return }
        try FileManager.default.removeItem(at: bookmarksPath)
    }

    /// Make sure this process can open the container's bind mounts before it starts.
    ///
    /// Supplied bookmarks from the embedder first — minted moments ago, and the only thing
    /// that works after a restart. Then whatever this container already holds from an earlier
    /// start in this boot. Then the boot-wide pool, which is how every CLI request gets its
    /// directories: either from grants the app already published, or by asking the app (which
    /// can put a panel in front of the user). Persisted bookmarks are last and only good
    /// within the boot that wrote them — a lapsed one decodes perfectly and opens nothing,
    /// which is what `HostDirectoryAccess.resolve` now notices (S6d).
    private func restoreHostDirectoryAccess(
        for id: String,
        configuration: ContainerConfiguration,
        at path: URL,
        supplied: [Data],
        askEmbedder: Bool = true
    ) async throws {
        let requiresAuthorization =
            ServiceIdentity.appGroup != nil && configuration.mounts.contains { $0.isVirtiofs }
        guard requiresAuthorization else {
            await self.hostDirectoryAccess.resolve(bookmarks: [], for: id)
            return
        }

        if !supplied.isEmpty {
            if await self.hostDirectoryAccess.resolve(bookmarks: supplied, for: id) {
                // Replaces what create wrote, so a later start with no embedder to ask still has
                // the most recent grants to try rather than the oldest.
                try? Self.persistHostDirectoryBookmarks(supplied, at: path)
                try await self.ensurePoolCoversBindMounts(of: configuration, askEmbedder: askEmbedder)
                return
            }
            // Not fatal, because the commonest way to get here is a grant that is newer than the
            // bookmarks carrying it. The embedder mints its set before it calls; if this same
            // call then raised a panel and the user granted the folder, the set it sent predates
            // the answer and opens nothing. Failing here told the user their authorization was
            // bad at the exact moment they had just given it — starting a machine failed once,
            // then worked on the next click, which is how this was found.
            //
            // So fall through to the sources that reflect the grant: what this container already
            // holds, what was persisted, and the boot-wide pool the panel just filled.
            self.log.info(
                "supplied bind-mount authorization did not open its directories; falling back",
                metadata: ["id": "\(id)"])
        }

        if await self.hostDirectoryAccess.hasGrants(for: id) {
            try await self.ensurePoolCoversBindMounts(of: configuration, askEmbedder: askEmbedder)
            return
        }

        let bundle = ContainerResource.Bundle(path: path)
        let bookmarksPath = bundle.filePath(for: Self.hostDirectoryBookmarksFilename)
        if FileManager.default.fileExists(atPath: bookmarksPath.path) {
            let bookmarks: [Data] = try bundle.load(filename: Self.hostDirectoryBookmarksFilename)
            if !bookmarks.isEmpty,
                await self.hostDirectoryAccess.resolve(bookmarks: bookmarks, for: id)
            {
                try await self.ensurePoolCoversBindMounts(of: configuration, askEmbedder: askEmbedder)
                return
            }
        }

        // CLI path, and the fallback when every bookmark source is empty or lapsed: the pool
        // is what the app published, or what it is about to grant from a panel.
        try await self.ensurePoolCoversBindMounts(of: configuration, askEmbedder: askEmbedder)
        await self.hostDirectoryAccess.resolve(bookmarks: [], for: id)
    }

    /// Every virtiofs source this container names must be openable in this process. Asks the
    /// embedder for any that is not — which may put a panel in front of the user — unless
    /// `askEmbedder` is false, as it is for the engine's own starts, which fail instead.
    private func ensurePoolCoversBindMounts(of configuration: ContainerConfiguration, askEmbedder: Bool = true) async throws {
        let sources = Set(configuration.mounts.filter(\.isVirtiofs).map(\.source))
        for source in sources where !(await HostDirectoryGrants.shared.covers(source)) {
            guard askEmbedder else {
                throw HostDirectoryNotGranted(source: source)
            }
            // Each outcome is a different thing for the user to do, so each says so. The old
            // single message covered them all and named the fix for only one of them.
            switch await HostDirectoryGrants.shared.request(source) {
            case .granted:
                continue
            case .declined:
                throw ContainerizationError(
                    .invalidArgument,
                    message:
                        "cannot mount \(source): permission for that folder was declined. Run this again and choose that folder when asked."
                )
            case .noEmbedder:
                throw ContainerizationError(
                    .invalidArgument,
                    message:
                        "cannot mount \(source): no permission for that folder, and the app is not open to ask for it. Open SiliconShip and try again, or mount a folder you have already granted."
                )
            case .timedOut:
                throw ContainerizationError(
                    .invalidArgument,
                    message:
                        "cannot mount \(source): the permission request was not answered within five minutes. Run this again and choose that folder when asked."
                )
            }
        }
    }

    private func getContainerCreationOptions(id: String) throws -> ContainerCreateOptions {
        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let options: ContainerCreateOptions = try bundle.load(filename: "options.json")
        return options
    }

    private func getInitBlock(for platform: Platform, imageRef: String? = nil) async throws -> Filesystem {
        let ref = imageRef ?? containerSystemConfig.vminit.image
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform, containerSystemConfig: containerSystemConfig)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL,
        debug: Bool
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", configuration.id,
            debug ? "--debug" : nil,
        ].compactMap { $0 }
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: path,
            args: args,
            instanceId: configuration.id
        )
    }

    private func setContainerState(_ id: String, _ state: ContainerState, context: AsyncLock.Context) async {
        let old = self.containers[id]?.snapshot
        self.containers[id] = state
        await self.peerMembershipChanged(old: old, new: state.snapshot)
    }

    // MARK: Peer hosts files

    /// Every change to what runs where passes through here: when a container starts running
    /// on its networks, stops running there, or goes away, the running containers on those
    /// networks have their hosts files rewritten. Not while the engine goes down, when
    /// everything stops and nobody is left to read them.
    private func peerMembershipChanged(old: ContainerSnapshot?, new: ContainerSnapshot?) async {
        guard !self.engineShuttingDown else { return }
        let networks = PeerHosts.networksToRefresh(old: old, new: new)
        guard !networks.isEmpty else { return }
        await self.peerHostsRefresher().request(networks: networks)
    }

    private func peerHostsRefresher() -> PeerHostsRefresher {
        if let peerHosts {
            return peerHosts
        }
        let refresher = PeerHostsRefresher(
            log: self.log,
            members: { [weak self] in await self?.peerHostsMembers() ?? [] },
            apply: { [weak self] rewrite in try await self?.applyPeerHosts(rewrite) })
        self.peerHosts = refresher
        return refresher
    }

    /// Wait for the rewrites asked for so far. Never fails: a guest that could not take its
    /// file was logged, and the operation that caused it stands.
    private func settlePeerHosts() async {
        await self.peerHosts?.settle()
    }

    private func peerHostsMembers() -> [PeerHosts.Member] {
        self.containers.values.compactMap { PeerHosts.member(of: $0.snapshot) }
    }

    private func applyPeerHosts(_ rewrite: PeerHosts.Rewrite) async throws {
        // Gone or stopped since the pass read it: nothing to write.
        guard let state = self.containers[rewrite.id], state.snapshot.status == .running, let client = state.client else {
            return
        }
        try await client.refreshHosts(peers: rewrite.peers, responseTimeout: Self.peerHostsResponseTimeout)
    }

    private func getContainerState(id: String, context: AsyncLock.Context) throws -> ContainerState {
        try self._getContainerState(id: id)
    }

    private func _getContainerState(id: String) throws -> ContainerState {
        let state = self.containers[id]
        guard let state else {
            throw ContainerizationError(
                .notFound,
                message: "container with ID \(id) not found"
            )
        }
        return state
    }

    private static func isInitProcess(id: String, processID: String) -> Bool {
        id == processID
    }

    /// Get container configuration, either from existing bundle or from RuntimeConfiguration
    private static func getContainerConfiguration(at path: URL) throws -> (ContainerConfiguration, ContainerCreateOptions?) {
        let bundle = ContainerResource.Bundle(path: path)
        do {
            let config = try bundle.configuration
            let options: ContainerCreateOptions? = try? bundle.load(filename: "options.json")
            return (config, options)
        } catch {
            // Bundle doesn't exist or incomplete, try runtime configuration
            // This handles containers that were created but not started yet
            let configurationError = error
            do {
                let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
                guard let config = runtimeConfig.containerConfiguration else {
                    throw ContainerizationError(.internalError, message: "runtime configuration missing container configuration")
                }
                return (config, runtimeConfig.options)
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to read config.json (\(configurationError)); runtime-configuration.json fallback also failed",
                    cause: error)
            }
        }
    }
}

extension XPCMessage {
    func signal() throws -> String {
        guard let signal = self.string(key: .signal) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: .stopOptions) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: .snapshot, value: data)
    }

    func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: .stdin) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: .stdout) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: .stderr) {
            handles[2] = stderr
        }
        return handles
    }

    func setFileHandle(_ handle: FileHandle) {
        self.set(key: .fd, value: handle)
    }

    func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: .processConfig) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }
}
