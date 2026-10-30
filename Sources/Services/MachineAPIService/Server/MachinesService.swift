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
import ContainerRuntimeClient
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import MachineAPIClient
import SystemPackage

// systemd poweroff signal (SIGRTMIN+4 on Linux, where SIGRTMIN=34 under glibc)
private let SIGRTMIN4: Int32 = 38

public actor MachinesService {
    private static let machinesDir = FilePath.Component("machines")
    private static let stateFile = FilePath.Component("state.json")

    private struct MachineState {
        var snapshot: MachineSnapshot

        var id: String { snapshot.configuration.id }

        var logger: Task<Void, Never>?
        var setupLease: MachineSetupLease?
        var runtimeIncarnation: String?
    }

    private var serviceState: ServiceState
    private let client: ContainerClient
    typealias BootSettings = (networkID: String, stopSignal: String?)
    private let bootSettings: @Sendable (MachineConfiguration) async throws -> BootSettings

    private let resourceRoot: FilePath
    private let machineRoot: FilePath
    private let lock = AsyncLock()
    private var machines: [String: MachineState]
    private let exitMonitor: ExitMonitor
    private let log: Logger

    private var `default`: MachineState? {
        guard let id = serviceState.defaultMachine else {
            return nil
        }
        // If a default is set but doesn't exist, treat as if no default is set
        // This can happen if the default container machine was deleted
        return self.machines[id]
    }

    public init(appRoot: FilePath, resourceRoot: FilePath, log: Logger) throws {
        try self.init(appRoot: appRoot, resourceRoot: resourceRoot, log: log, client: ContainerClient())
    }

    init(
        appRoot: FilePath, resourceRoot: FilePath, log: Logger, client: ContainerClient,
        bootSettings: @escaping @Sendable (MachineConfiguration) async throws -> BootSettings = MachinesService.resolveBootSettings
    ) throws {
        self.resourceRoot = resourceRoot

        let machineRoot = appRoot.appending(Self.machinesDir)
        try FileManager.default.createDirectory(atPath: machineRoot.string, withIntermediateDirectories: true)
        self.machineRoot = machineRoot
        self.serviceState = try ServiceState.from(appRoot.appending(Self.stateFile))

        self.log = log
        self.machines = try Self.loadAtBoot(root: machineRoot, resourceRoot: resourceRoot, log: log)
        self.client = client
        self.bootSettings = bootSettings
        self.exitMonitor = ExitMonitor(log: log)
    }

    static func resolveBootSettings(_ configuration: MachineConfiguration) async throws -> BootSettings {
        guard let network = try await NetworkClient().builtin else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        // Retain the image stop signal, defaulting to SIGTERM when image metadata is unavailable.
        let imageConfig = try? await ClientImage(description: configuration.image).config(for: configuration.platform).config
        return (network.id, imageConfig?.stopSignal)
    }

    static private func loadAtBoot(root: FilePath, resourceRoot: FilePath, log: Logger) throws -> [String: MachineState] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.string)

        var results = [String: MachineState]()
        for entry in entries {
            guard let component = FilePath.Component(entry) else {
                continue
            }
            let dir = root.appending(component)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.string, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            do {
                try MachineBundle.sync(path: dir, resourceRoot: resourceRoot)
            } catch {
                log.error("failed to sync resources for machine bundle", metadata: ["path": "\(dir.string)", "error": "\(error)"])
                continue
            }

            do {
                let bundle = MachineBundle(path: dir)
                let config = try bundle.configuration
                let bootConfig = try bundle.bootConfig

                let state = MachineState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        bootConfig: bootConfig,
                        createdDate: try? bundle.createdDate,
                        containerId: nil,
                        initialized: bundle.initialized
                    )
                )

                results[config.id] = state
            } catch {
                log.warning("failed to load machine bundle", metadata: ["path": "\(dir.string)", "error": "\(error)"])
            }
        }

        return results
    }

    static private func pipeFile(from: FileHandle, to: FileHandle) async throws {
        try to.seekToEnd()

        let stream = AsyncStream<Data> { cont in
            from.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    from.readabilityHandler = nil
                    cont.finish()
                    return
                }

                cont.yield(data)
            }
        }

        for await data in stream {
            try to.write(contentsOf: data)
        }
    }

    public func list() async throws -> [MachineSnapshot] {
        self.log.debug("\(#function)")
        var snapshots: [MachineSnapshot] = []
        for state in self.machines.values {
            var snapshot = state.snapshot
            let path = try self.bundlePath(id: snapshot.id)
            let bundle = MachineBundle(path: path)
            snapshot.diskSize = bundle.diskSize
            snapshot.initialized = bundle.initialized
            snapshots.append(snapshot)
        }
        let runningIds = snapshots.compactMap { $0.status == .running ? $0.containerId : nil }
        if !runningIds.isEmpty {
            var containers: [ContainerSnapshot]?
            do {
                containers = try await self.client.list(filters: ContainerListFilters(ids: runningIds))
            } catch {
                self.log.warning("failed to fetch container addresses: \(error)")
            }
            let addressMap = (containers ?? []).reduce(into: [String: String]()) { result, c in
                if let addr = c.networks.first?.ipv4Address.address.description {
                    result[c.id] = addr
                }
            }
            for i in snapshots.indices where snapshots[i].status == .running {
                if let cid = snapshots[i].containerId {
                    snapshots[i].ipAddress = addressMap[cid]
                }
            }
        }
        return snapshots
    }

    public func create(configuration: MachineConfiguration, bootConfig: MachineConfig) async throws {
        self.log.debug("\(#function)")
        try Self.validateMemory(of: bootConfig)

        try await self.lock.withLock { context in
            guard await self.machines[configuration.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container machine already exists: \(configuration.id)"
                )
            }

            let path = try self.bundlePath(id: configuration.id)
            let bundle = try MachineBundle.create(
                path: path,
                machineConfiguration: configuration,
                resourceRoot: self.resourceRoot,
                bootConfig: bootConfig,
            )

            do {
                let machineImage = ClientImage(description: configuration.image)
                let imageFs = try await machineImage.getCreateSnapshot(platform: configuration.platform)
                try bundle.setMachineRootFs(cloning: imageFs)

                let state = MachineState(
                    snapshot: .init(
                        configuration: configuration,
                        status: .stopped,
                        bootConfig: bootConfig,
                        createdDate: Date(),
                        containerId: nil,
                    )
                )
                await self.setMachineState(configuration.id, state, context: context)

                if await self.default == nil {
                    try await self._setDefault(id: configuration.id)
                }
            } catch {
                do {
                    try bundle.delete()
                } catch {
                    self.log.error("failed to delete bundle for container machine \(configuration.id)")
                }

                throw error
            }
        }
    }

    public func delete(id: String) async throws {
        self.log.debug("\(#function)")

        try await self.lock.withLock { context in
            let state = try await self._getMachineState(id: id)

            switch state.snapshot.status {
            case .running:
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine \(id) is \(state.snapshot.status)")
            default:
                break
            }

            if let defaultMachine = await self.default, defaultMachine.id == id {
                try await self._setDefault(id: nil)
            }

            try await self._cleanUp(id: id)
        }
    }

    public func getDefault() async throws -> String? {
        self.log.debug("\(#function)")

        return self.default?.id
    }

    public func setDefault(id: String) async throws {
        self.log.debug("\(#function)")

        try await self.lock.withLock { context in
            let state = try await self._getMachineState(id: id)
            try await self._setDefault(id: state.id)
        }
    }

    public func setConfig(id: String, bootConfig: MachineConfig) async throws {
        self.log.debug("\(#function)")
        try Self.validateMemory(of: bootConfig)
        try await self.lock.withLock { context in
            var state = try await self._getMachineState(id: id)
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)
            try bundle.set(bootConfig: bootConfig)

            state.snapshot.bootConfig = bootConfig
            await self.setMachineState(id, state, context: context)
        }
    }

    /// Refuses a machine memory no VM can have: the machine's container is limited to it, and
    /// its VM is that plus the guest's reserve, which Virtualization caps.
    static func validateMemory(
        of bootConfig: MachineConfig, virtualMemory: UInt64 = ContainerConfiguration.Resources.maximumVirtualMemory
    ) throws {
        var resources = ContainerConfiguration.Resources()
        resources.memoryInBytes = bootConfig.memory.toUInt64(unit: .bytes)
        try resources.validateMemory(virtualMemory: virtualMemory)
    }

    private func _getMachineState(id: String) throws -> MachineState {
        let state = self.machines[id]
        guard let state else {
            throw ContainerizationError(
                .notFound,
                message: "container machine with ID \(id) not found")
        }
        return state
    }

    private func setMachineState(_ id: String, _ state: MachineState, context: AsyncLock.Context) async {
        self.machines[id] = state
    }

    private nonisolated func bundlePath(id: String) throws -> FilePath {
        guard let component = FilePath.Component(id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container machine ID \(id) is not a valid path component"
            )
        }
        return self.machineRoot.appending(component)
    }

    private func _setDefault(id: String?) throws {
        try serviceState.setDefault(id: id)
    }

    private func _cleanUp(id: String) throws {
        self.log.debug("\(#function)")

        if self.machines[id] == nil {
            return
        }

        let path = try self.bundlePath(id: id)
        let bundle = MachineBundle(path: path)
        try bundle.delete()
        self.machines.removeValue(forKey: id)
    }

    private func cleanUp(id: String, context: AsyncLock.Context) async throws {
        try self._cleanUp(id: id)
    }

    private nonisolated func systemPlatform(from ociPlatform: ContainerizationOCI.Platform) -> SystemPlatform {
        ociPlatform.architecture == "amd64" ? .linuxAmd : .linuxArm
    }

    /// - Parameter hostDirectoryBookmarks: authorization for the home directory this machine
    ///   mounts, from the embedder. Forwarded to the container service, which is what actually
    ///   holds the grant — this process only assembles the configuration.
    public func boot(
        id: String?,
        dynamicEnv: [String: String] = [:],
        hostDirectoryBookmarks: [Data] = []
    ) async throws -> MachineSnapshot {
        let result = try await boot(id: id, dynamicEnv: dynamicEnv, hostDirectoryBookmarks: hostDirectoryBookmarks, coordinated: false)
        switch result {
        case .started(let snapshot, _), .existing(let snapshot): return snapshot
        }
    }

    public func bootForSetup(
        id: String?, dynamicEnv: [String: String] = [:], hostDirectoryBookmarks: [Data] = []
    ) async throws -> MachineBootResult {
        try await boot(id: id, dynamicEnv: dynamicEnv, hostDirectoryBookmarks: hostDirectoryBookmarks, coordinated: true)
    }

    private func boot(
        id: String?, dynamicEnv: [String: String], hostDirectoryBookmarks: [Data], coordinated: Bool
    ) async throws -> MachineBootResult {
        self.log.debug("\(#function)")

        guard let id = id ?? self.default?.id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no container machine specified and no default set"
            )
        }

        return try await self.lock.withLock { context in
            var state = try await self._getMachineState(id: id)
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)

            switch state.snapshot.status {
            case .running:
                // Refresh persisted first-boot status. Setup ownership is tracked
                // separately for this VM's current boot.
                state.snapshot.initialized = bundle.initialized
                await self.setMachineState(id, state, context: context)
                return .existing(snapshot: state.snapshot)
            case .stopped:
                break
            default:
                throw ContainerizationError(.invalidState, message: "container machine \(id) is \(state.snapshot.status)")
            }

            let cid = "\(id)-\(UUID().uuidString.prefix(MachineConfiguration.containerUUIDLength).lowercased())"
            guard try await self.client.list(filters: .init(ids: [cid])).isEmpty else {
                throw ContainerizationError(.internalError, message: "container \(cid) already exists")
            }

            let rootfs = try bundle.machineRootfs

            let bootConfig = state.snapshot.bootConfig
            let settings = try await self.bootSettings(state.snapshot.configuration)
            var config = state.snapshot.configuration.toContainerConfig(
                cid: cid,
                sbin: path.appending(MachineBundle.sbinDirectory),
                initializedFile: path.appending(MachineBundle.initializedFile),
                homeMountOption: bootConfig.homeMount,
                virtualization: bootConfig.virtualization,
                settings: settings
            )

            config.resources.cpus = bootConfig.cpus
            config.resources.cpuOverhead = 0
            config.resources.memoryInBytes = bootConfig.memory.toUInt64(unit: .bytes)

            let kernel: Kernel
            if let kernelPath = bootConfig.kernelPath {
                let validated = try MachineConfig.validateKernelPath(kernelPath.string)
                kernel = Kernel(
                    path: URL(fileURLWithPath: validated.string),
                    platform: self.systemPlatform(from: state.snapshot.configuration.platform)
                )
            } else {
                kernel = try await ClientKernel.getDefaultKernel(for: .current)
            }

            var fhs: [FileHandle] = []
            let incarnation = UUID().uuidString.lowercased()
            do {
                try await self.client.create(
                    configuration: config,
                    options: ContainerCreateOptions(autoRemove: true, rootFsOverride: rootfs),
                    kernel: kernel,
                    hostDirectoryBookmarks: hostDirectoryBookmarks,
                    incarnation: incarnation
                )

                let process = try await self.client.bootstrap(
                    id: cid, stdio: [nil, nil, nil], dynamicEnv: dynamicEnv,
                    hostDirectoryBookmarks: hostDirectoryBookmarks)
                try await process.start()

                try fhs.append(contentsOf: await self.client.logs(id: cid))

                try bundle.createLogFiles()
                let stdioLog = try FileHandle(forWritingTo: URL(filePath: bundle.stdioLog.string))
                let bootLog = try FileHandle(forWritingTo: URL(filePath: bundle.bootLog.string))

                state.logger = Task<Void, Never> { [log = self.log, id = state.id, fhs] in
                    defer {
                        try? fhs[0].close()
                        try? fhs[1].close()

                        try? stdioLog.close()
                        try? bootLog.close()
                    }

                    await withTaskGroup(of: Result<Void, Error>.self) { group in
                        for (from, to) in zip(fhs, [stdioLog, bootLog]) {
                            group.addTask {
                                do {
                                    try await Self.pipeFile(from: from, to: to)
                                    return .success(())
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }

                        for await result in group {
                            switch result {
                            case .success():
                                continue
                            case .failure(let error):
                                log.error(
                                    "log pipe failed",
                                    metadata: [
                                        "id": "\(id)",
                                        "error": "\(error)",
                                    ])
                            }
                        }
                    }
                }

                try await self.exitMonitor.registerProcess(
                    id: id,
                    onExit: { id, code in
                        await self.handleMachineExit(id: id, code: code, containerID: cid, incarnation: incarnation)
                    }
                )

                state.snapshot.status = .running
                state.snapshot.startedDate = Date()
                state.snapshot.containerId = cid
                state.runtimeIncarnation = incarnation
                state.setupLease = coordinated ? MachineSetupLease(machineID: id, containerID: cid, token: UUID()) : nil
                state.snapshot.setupPending = coordinated
                state.snapshot.initialized = bundle.initialized
                await self.setMachineState(id, state, context: context)

                // Monitor container exit in the background so we can update container machine state
                // when the backing container stops (e.g., VM crash, kill, etc.)
                try await self.exitMonitor.track(id: id) {
                    self.log.info("registering container machine with exit monitor")
                    let code = try await process.wait()
                    self.log.info(
                        "container machine exited in exit monitor",
                        metadata: ["id": "\(id)", "rc": "\(code)"]
                    )

                    return ExitStatus(exitCode: code)
                }

                if let lease = state.setupLease { return .started(snapshot: state.snapshot, lease: lease) }
                return .existing(snapshot: state.snapshot)
            } catch {
                await self.exitMonitor.stopTracking(id: id)

                state.logger?.cancel()
                await state.logger?.value
                state.logger = nil

                fhs.forEach { try? $0.close() }
                try? await self.client.delete(id: cid, force: true, expectedIncarnation: incarnation)

                state.setupLease = nil
                state.runtimeIncarnation = nil
                state.snapshot.setupPending = false
                state.snapshot.status = .stopped
                state.snapshot.startedDate = nil
                state.snapshot.containerId = nil
                state.snapshot.ipAddress = nil
                await self.setMachineState(id, state, context: context)

                throw error
            }
        }
    }

    /// The user's home directory as the system records it, unaffected by sandbox
    /// redirection. Falls back to Foundation only if the password entry is unreadable, which
    /// would mean something far more broken than a mount.
    static var realHomeDirectory: String {
        guard let entry = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return String(cString: entry.pointee.pw_dir)
    }

    func stopAfterSetupDisconnect(_ lease: MachineSetupLease) async {
        do {
            // Cleanup must still run if the connection handler was cancelled.
            let cleanup = Task { try await self.stopSetup(lease) }
            _ = try await cleanup.value
        } catch {
            log.warning("failed to stop abandoned machine setup", metadata: ["id": "\(lease.machineID)", "error": "\(error)"])
        }
    }

    public func completeSetup(_ lease: MachineSetupLease) async throws -> MachineSnapshot {
        try await self.lock.withLock { context in
            var state = try await self._getMachineState(id: lease.machineID)
            guard state.setupLease == lease, state.snapshot.status == .running,
                state.snapshot.containerId == lease.containerID, state.snapshot.setupPending
            else { throw ContainerizationError(.invalidState, message: "machine setup no longer owns this VM") }
            // Revoke rollback authority before followers are allowed to use the VM. A lost
            // completion reply must not let the old caller stop a successfully prepared VM.
            state.setupLease = nil
            state.snapshot.setupPending = false
            let path = try self.bundlePath(id: lease.machineID)
            state.snapshot.initialized = MachineBundle(path: path).initialized
            await self.setMachineState(lease.machineID, state, context: context)
            return state.snapshot
        }
    }

    public func stopSetup(_ lease: MachineSetupLease) async throws -> Bool {
        try await self.lock.withLock { context in
            guard let state = try? await self._getMachineState(id: lease.machineID),
                state.setupLease == lease, state.snapshot.setupPending,
                state.snapshot.containerId == lease.containerID, state.snapshot.status == .running
            else { return false }
            try await self.stopLocked(id: lease.machineID, context: context)
            return true
        }
    }

    public func stop(id: String) async throws {
        self.log.debug("\(#function)")
        try await self.lock.withLock { context in
            try await self.stopLocked(id: id, context: context)
        }
    }

    private func stopLocked(id: String, context: AsyncLock.Context) async throws {
        let state = try self._getMachineState(id: id)

        switch state.snapshot.status {
        case .stopped:
            return
        case .running:
            break
        default:
            throw ContainerizationError(
                .invalidState,
                message: "container machine \(id) is \(state.snapshot.status)"
            )
        }

        guard let cid = state.snapshot.containerId else {
            throw ContainerizationError(
                .internalError,
                message: "no container ID for running container machine"
            )
        }

        guard let incarnation = state.runtimeIncarnation else {
            throw ContainerizationError(.invalidState, message: "running machine has no backing container identity")
        }
        try await self.client.stop(id: cid, opts: ContainerStopOptions(timeoutInSeconds: 10, signal: nil), expectedIncarnation: incarnation)
        await self.handleMachineExit(id: id, code: nil, containerID: cid, incarnation: incarnation, context: context)
    }

    func handleMachineExit(id: String, code: ExitStatus?, containerID: String, incarnation: String) async {
        await self.lock.withLock { [self] context in
            await handleMachineExit(id: id, code: code, containerID: containerID, incarnation: incarnation, context: context)
        }
    }

    private func handleMachineExit(id: String, code: ExitStatus?, containerID: String, incarnation: String, context: AsyncLock.Context) async {
        self.log.info("container exited for container machine \(id)")
        guard var state = self.machines[id], state.snapshot.containerId == containerID, state.runtimeIncarnation == incarnation else {
            return
        }
        state.setupLease = nil
        state.runtimeIncarnation = nil
        state.snapshot.setupPending = false
        state.snapshot.status = .stopped
        state.snapshot.startedDate = nil
        state.snapshot.containerId = nil
        state.snapshot.ipAddress = nil

        state.logger?.cancel()
        await state.logger?.value
        state.logger = nil

        await self.exitMonitor.stopTracking(id: id)
        await self.setMachineState(id, state, context: context)
    }

    public func inspect(id: String) async throws -> MachineSnapshot {
        self.log.debug("\(#function)")
        var snapshot = try self._getMachineState(id: id).snapshot
        let path = try self.bundlePath(id: id)
        let bundle = MachineBundle(path: path)
        snapshot.initialized = bundle.initialized
        snapshot.diskSize = bundle.diskSize
        if snapshot.status == .running, let cid = snapshot.containerId {
            do {
                let container = try await self.client.get(id: cid)
                snapshot.ipAddress = container.networks.first?.ipv4Address.address.description
            } catch {
                self.log.warning("failed to fetch container address for \(cid): \(error)")
            }
        }
        return snapshot
    }

    // Get the logs for the container machine
    public func logs(id: String) async throws -> [FileHandle] {
        self.log.debug("\(#function)")

        do {
            _ = try _getMachineState(id: id)
            let path = try self.bundlePath(id: id)
            let bundle = MachineBundle(path: path)
            return [
                try FileHandle(forReadingFrom: URL(filePath: bundle.stdioLog.string)),
                try FileHandle(forReadingFrom: URL(filePath: bundle.bootLog.string)),
            ]
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container machine logs: \(error)")
        }
    }
}

extension MachinesService {
    fileprivate struct ServiceState: Codable, Sendable {
        private var path: FilePath?

        public var defaultMachine: String?

        enum CodingKeys: String, CodingKey {
            case defaultMachine
        }

        public static func from(_ path: FilePath) throws -> ServiceState {
            var state: ServiceState

            let url = URL(filePath: path.string)
            do {
                let data = try Data(contentsOf: url)
                state = try JSONDecoder().decode(Self.self, from: data)
            } catch {
                state = ServiceState(defaultMachine: nil)
                try JSONEncoder().encode(state).write(to: url)
            }

            state.path = path
            return state
        }

        public mutating func setDefault(id: String?) throws {
            guard let path else {
                throw ContainerizationError(
                    .internalError,
                    message: "service state path is not set"
                )
            }

            self.defaultMachine = id
            let data = try JSONEncoder().encode(self)
            try data.write(to: URL(filePath: path.string), options: .atomic)
        }
    }
}

extension MachineBundle {
    func createLogFiles() throws {
        let bootLogFd = Darwin.open(self.bootLog.string, O_CREAT | O_RDONLY, 0o644)
        guard bootLogFd > 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        close(bootLogFd)

        let stdioLogFd = Darwin.open(self.stdioLog.string, O_CREAT | O_RDONLY, 0o644)
        guard stdioLogFd > 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        close(stdioLogFd)
    }
}

extension MachineConfiguration {
    fileprivate func toContainerConfig(
        cid: String,
        sbin: FilePath,
        initializedFile: FilePath,
        homeMountOption: MachineConfig.HomeMountOption,
        virtualization: Bool,
        settings: MachinesService.BootSettings
    ) -> ContainerConfiguration {
        var config = ContainerConfiguration(
            id: cid,
            image: image,
            process: ProcessConfiguration(
                executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
                arguments: [],
                environment: processEnvironment,
                workingDirectory: "/",
                terminal: true,
                user: .id(uid: 0, gid: 0)
            )
        )

        // The real home, from the password database — not Foundation's answer.
        //
        // Inside an App Sandbox, `homeDirectoryForCurrentUser` and `NSHomeDirectory()` are
        // both redirected to the embedder's container, so a machine would mount
        // ~/Library/Containers/<bundle-id>/Data and the guest would see a home directory
        // holding nothing but `Library`. It boots and looks like it worked. `getpwuid` is not
        // redirected, and this is the directory the user means.
        let home = MachinesService.realHomeDirectory
        config.mounts = [
            .virtiofs(
                source: sbin.string,
                destination: "/\(MachineBundle.sbinDirectory)",
                options: ["ro"]),
            .virtiofs(
                source: initializedFile.string,
                destination: "/etc/.\(MachineBundle.initializedFile)",
                options: ["rw"]),
        ]
        if homeMountOption != .none {
            config.mounts.append(
                .virtiofs(
                    source: home,
                    destination: home,
                    options: [homeMountOption.rawValue]
                )
            )
        }

        config.platform = platform
        config.labels = [
            ResourceLabelKeys.plugin: ResourcePluginValues.machine
        ]
        let domain = Self.defaultDNSDomain
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: [],
            domain: domain,
            searchDomains: [domain],
        )
        config.networks = [
            AttachmentConfiguration(
                network: settings.networkID,
                options: AttachmentOptions(hostname: dnsHostname)
            )
        ]

        config.capAdd = ["ALL"]
        config.ssh = true
        config.virtualization = virtualization
        config.readonlyPaths = []
        config.maskedPaths = []
        config.writableSysfs = true

        config.rosetta = platform.architecture == "amd64" && Arch.hostArchitecture() == .arm64

        config.stopSignal = settings.stopSignal

        return config
    }
}
