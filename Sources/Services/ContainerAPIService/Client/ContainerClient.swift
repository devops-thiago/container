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

import ContainerResource
import ContainerVersion
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

/// A client for interacting with the container API server.
///
/// This client holds a reusable XPC connection and provides methods for
/// container lifecycle operations. All methods that operate on a specific
/// container take an `id` parameter.
public struct ContainerClient: Sendable {
    private static let serviceIdentifier = ServiceIdentity.apiServerService

    private let xpcClient: XPCClient
    private let makeGrantAwareClient: @Sendable () -> XPCClient

    /// Creates a new container client with a connection to the API server.
    public init() {
        self.init(xpcClient: XPCClient(service: Self.serviceIdentifier))
    }

    init(
        xpcClient: XPCClient,
        makeGrantAwareClient: @escaping @Sendable () -> XPCClient = { XPCClient(service: ServiceIdentity.apiServerService) }
    ) {
        self.xpcClient = xpcClient
        self.makeGrantAwareClient = makeGrantAwareClient
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = XPCClient.xpcRegistrationTimeout
    ) async throws -> XPCMessage {
        guard timeout == Self.grantAwareTimeout else {
            return try await xpcClient.send(message, responseTimeout: timeout)
        }

        // A grant-capable operation owns its connection. Local task cancellation can therefore
        // close exactly this request without disrupting other calls on the reusable client; the
        // API server observes that connection loss and cancels HostDirectoryGrants in turn.
        let client = makeGrantAwareClient()
        let transport = GrantAwareTransport(
            send: { message, timeout in
                try await client.send(message, responseTimeout: timeout)
            },
            close: { client.close() })
        defer { transport.close() }
        return try await Self.sendGrantAware(message, timeout: Self.grantAwareTimeout, over: transport)
    }

    struct GrantAwareTransport: Sendable {
        let send: @Sendable (XPCMessage, Duration) async throws -> XPCMessage
        let close: @Sendable () -> Void
    }

    static func sendGrantAware(
        _ message: XPCMessage,
        timeout: Duration,
        over transport: GrantAwareTransport
    ) async throws -> XPCMessage {
        try await withTaskCancellationHandler {
            try await transport.send(message, timeout)
        } onCancel: {
            transport.close()
        }
    }

    /// Puts who a request is for on it, when there is something showable to put. The engine
    /// sanitizes it again: this is only the polite half.
    static func setRequester(_ requester: String?, on request: XPCMessage) {
        guard let requester = GrantRequester.sanitized(requester) else { return }
        request.set(key: .hostDirectoryRequester, value: requester)
    }

    /// For calls that can end up waiting on a permission panel.
    ///
    /// Creating or starting a container whose bind mount names an ungranted folder makes the
    /// engine ask the embedder, which may put a picker in front of someone. See
    /// `XPCClient.grantAwareResponseTimeout` for why this has to outlast that wait.
    private static let grantAwareTimeout: Duration = XPCClient.grantAwareResponseTimeout

    /// Create a new container with the given configuration.
    ///
    /// - Parameter hostDirectoryBookmarks: bookmarks for host directories this container
    ///   will bind-mount, made by a sandboxed embedder for folders its user chose. Empty for
    ///   an unsandboxed engine, which opens paths without needing a grant.
    /// - Parameter requester: who this create is for, as a folder-permission panel should name
    ///   it (`docker (pid 4242)`), when the caller acts for another process. nil names the
    ///   caller itself. Display only.
    @discardableResult
    public func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel,
        initImage: String? = nil,
        runtimeData: Data? = nil,
        hostDirectoryBookmarks: [Data] = [],
        incarnation requestedIncarnation: String? = nil,
        requester: String? = nil
    ) async throws -> String {
        do {
            let request = XPCMessage(route: .containerCreate)
            Self.setRequester(requester, on: request)
            let incarnation = requestedIncarnation ?? UUID().uuidString.lowercased()

            let data = try JSONEncoder().encode(configuration)
            let kdata = try JSONEncoder().encode(kernel)
            let odata = try JSONEncoder().encode(options)
            request.set(key: .containerConfig, value: data)
            request.set(key: .kernel, value: kdata)
            request.set(key: .containerOptions, value: odata)

            if let initImage {
                request.set(key: .initImage, value: initImage)
            }

            if let runtimeData {
                request.set(key: .runtimeData, value: runtimeData)
            }

            // JSON like every other structured field on this route: XPCMessage carries data,
            // strings and scalars, not arrays. Data encodes as base64 here, which is what
            // keeps a bookmark's bytes intact across the boundary.
            if !hostDirectoryBookmarks.isEmpty {
                request.set(
                    key: .hostDirectoryBookmarks,
                    value: try JSONEncoder().encode(hostDirectoryBookmarks))
            }

            request.set(key: .expectedIncarnation, value: incarnation)
            let response = try await xpcSend(message: request, timeout: Self.grantAwareTimeout)
            guard let returnedIncarnation = response.string(key: .expectedIncarnation),
                returnedIncarnation == incarnation
            else {
                throw ContainerizationError(
                    .internalError,
                    message: "container create did not confirm its requested incarnation")
            }
            return incarnation
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container",
                cause: error
            )
        }
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        do {
            let request = XPCMessage(route: .containerList)
            let filterData = try JSONEncoder().encode(filters)
            request.set(key: .listFilters, value: filterData)

            let response = try await xpcSend(
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: .containers)
            guard let data else {
                return []
            }
            return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list containers",
                cause: error
            )
        }
    }

    /// Get the container for the provided id.
    public func get(id: String) async throws -> ContainerSnapshot {
        let containers = try await list(filters: ContainerListFilters(ids: [id]))
        guard let container = containers.first else {
            throw ContainerizationError(
                .notFound,
                message: "get failed: container \(id) not found"
            )
        }
        return container
    }

    /// Bootstrap the container's init process.
    ///
    /// - Parameter hostDirectoryBookmarks: fresh grants for the container's bind mounts, for a
    ///   sandboxed engine. Supplying them on every start rather than only at create is what
    ///   makes a bind mount survive a restart: the grant a bookmark carries lapses when the
    ///   machine reboots, and the bytes the engine persisted at create cannot bring it back
    ///   (`docs/sandbox-spikes.md`, S6d). Empty means "use whatever you already have", which is
    ///   correct unsandboxed and for a caller that holds no grants of its own.
    /// - Parameter requester: who this start is for, as `create` takes it.
    public func bootstrap(
        id: String,
        stdio: [FileHandle?],
        dynamicEnv: [String: String] = [:],
        hostDirectoryBookmarks: [Data] = [],
        requester: String? = nil
    ) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerBootstrap)
        Self.setRequester(requester, on: request)

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        do {
            let dynamicEnv = try JSONEncoder().encode(dynamicEnv)
            request.set(key: .dynamicEnv, value: dynamicEnv)

            if !hostDirectoryBookmarks.isEmpty {
                request.set(
                    key: .hostDirectoryBookmarks,
                    value: try JSONEncoder().encode(hostDirectoryBookmarks))
            }

            request.set(key: .id, value: id)
            // Starting can ask for folders too: a container created while the app held grants
            // may be started later from a terminal with nothing resolved, and the engine has
            // to be able to ask before this gives up on it.
            try await xpcSend(message: request, timeout: Self.grantAwareTimeout)
            return ClientProcessImpl(containerId: id, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container",
                cause: error
            )
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, signal: String) async throws {
        do {
            let request = XPCMessage(route: .containerKill)
            request.set(key: .id, value: id)
            request.set(key: .processIdentifier, value: id)
            request.set(key: .signal, value: signal)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container",
                cause: error
            )
        }
    }

    /// Stop the container and all processes currently executing inside.
    /// - Parameters:
    ///   - requiredLabels: labels the container must carry. This is an ownership-policy
    ///     precondition; use `expectedIncarnation` when the exact observed object matters.
    ///   - expectedIncarnation: opaque identity returned in `ContainerSnapshot`. The service
    ///     checks it against the object it acts on and again during post-stop cleanup.
    public func stop(
        id: String,
        opts: ContainerStopOptions = ContainerStopOptions.default,
        requiredLabels: [String: String]? = nil,
        expectedIncarnation: String? = nil
    ) async throws {
        do {
            let request = XPCMessage(route: .containerStop)
            let data = try JSONEncoder().encode(opts)
            request.set(key: .id, value: id)
            request.set(key: .stopOptions, value: data)
            if let requiredLabels {
                request.set(key: .requiredLabels, value: try JSONEncoder().encode(requiredLabels))
            }
            if let expectedIncarnation {
                request.set(key: .expectedIncarnation, value: expectedIncarnation)
            }

            try await xpcClient.send(request)
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Delete the container along with any resources.
    ///
    /// Both preconditions are checked under the service lock immediately before removal.
    public func delete(
        id: String,
        force: Bool = false,
        requiredLabels: [String: String]? = nil,
        expectedIncarnation: String? = nil
    ) async throws {
        do {
            let request = XPCMessage(route: .containerDelete)
            request.set(key: .id, value: id)
            request.set(key: .forceDelete, value: force)
            if let requiredLabels {
                request.set(key: .requiredLabels, value: try JSONEncoder().encode(requiredLabels))
            }
            if let expectedIncarnation {
                request.set(key: .expectedIncarnation, value: expectedIncarnation)
            }
            try await xpcClient.send(request)
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }

    /// Get the disk usage for a container.
    public func diskUsage(id: String) async throws -> UInt64 {
        let request = XPCMessage(route: .containerDiskUsage)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)

        let size = reply.uint64(key: .containerSize)
        return size
    }

    /// What the container wrote to its root filesystem, as Docker reports `SizeRw`, or nil
    /// when the engine cannot tell: while it runs, for one example.
    public func writableSize(id: String) async throws -> UInt64? {
        let request = XPCMessage(route: .containerWritableSize)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)
        return reply.uint64IfPresent(key: .containerWritableSize)
    }

    /// Create a new process inside a running container.
    /// The process is in a created state and must still be started.
    /// An optional deadline bounds creation and subsequent start/wait requests together.
    public func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?],
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> ClientProcess {
        do {
            let request = XPCMessage(route: .containerCreateProcess)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: processId)

            let data = try JSONEncoder().encode(configuration)
            request.set(key: .processConfig, value: data)

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            try await sendProcessRequest(request, using: xpcClient, deadline: deadline)
            return ClientProcessImpl(containerId: containerId, processId: processId, xpcClient: xpcClient, deadline: deadline)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process in container",
                cause: error
            )
        }
    }

    /// Get the log file handles for a container.
    public func logs(id: String) async throws -> [FileHandle] {
        do {
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: id)

            let response = try await xpcClient.send(request)
            let fds = response.fileHandles(key: .logs)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fds returned"
                )
            }
            return fds
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get logs for container \(id)",
                cause: error
            )
        }
    }

    /// Preflight the entire selection before authorizing any legacy managed container.
    /// Callers must invoke this before starting or recreating any selected container.
    public func prepareWritableSysfs(
        _ snapshots: [ContainerSnapshot], role: ManagedSysfsRole, adoptLegacy: Bool, adoptionCommand: String
    ) async throws {
        let legacy = snapshots.filter { !$0.configuration.writableSysfs }
        for node in legacy {
            guard adoptLegacy else {
                throw ContainerizationError(.invalidState, message: "legacy container \(node.id) needs explicit adoption: \(adoptionCommand)")
            }
            guard node.status == .stopped else {
                throw ContainerizationError(.invalidState, message: "stop legacy container \(node.id) before adopting it")
            }
        }
        for node in legacy {
            try Task.checkCancellation()
            try await adoptWritableSysfs(id: node.id, expectedIncarnation: node.incarnation, role: role)
        }
    }

    /// Explicitly authorize writable /sys for the observed legacy managed container.
    public func adoptWritableSysfs(id: String, expectedIncarnation: String, role: ManagedSysfsRole) async throws {
        let request = XPCMessage(route: .containerAdoptWritableSysfs)
        request.set(key: .id, value: id)
        request.set(key: .expectedIncarnation, value: expectedIncarnation)
        request.set(key: .sysfsRole, value: role.rawValue)
        try await xpcClient.send(request, responseTimeout: .seconds(10))
    }

    /// Update the guest agent of the exact stopped container the caller observed.
    public func upgradeGuest(id: String, expectedIncarnation: String) async throws {
        let request = XPCMessage(route: .containerUpgradeGuest)
        request.set(key: .id, value: id)
        request.set(key: .expectedIncarnation, value: expectedIncarnation)
        try await xpcClient.send(request, responseTimeout: .seconds(300))
    }

    /// Set labels on a container. The server lets only some keys change (its
    /// `ContainerLabelPolicy`); any other is refused, and nothing is changed.
    ///
    /// - Parameter expectedIncarnation: the exact container observed; another one made since
    ///   under the same ID is not changed.
    public func updateLabels(id: String, labels: [String: String], expectedIncarnation: String? = nil) async throws {
        let request = XPCMessage(route: .containerUpdateLabels)
        request.set(key: .id, value: id)
        request.set(key: .containerLabels, value: try JSONEncoder().encode(labels))
        if let expectedIncarnation {
            request.set(key: .expectedIncarnation, value: expectedIncarnation)
        }
        do {
            try await xpcClient.send(request, responseTimeout: .seconds(10))
        } catch let error as ContainerizationError {
            throw error
        } catch {
            throw ContainerizationError(.internalError, message: "failed to set labels on container \(id)", cause: error)
        }
    }

    /// Subscribe to the API server's container events.
    ///
    /// - Parameter since: the last event read from an earlier subscription. The events after it
    ///   come first when the server still has them all; otherwise the subscription says `gap`.
    ///   nil asks for the events from now on.
    public func events(since: ContainerEventCursor? = nil) async throws -> ContainerEventSubscription {
        let request = XPCMessage(route: .containerEvent)
        if let since {
            request.set(key: .processNonce, value: since.processNonce)
            request.set(key: .eventsSince, value: since.sequence)
        }
        let response: XPCMessage
        do {
            response = try await xpcClient.send(request, responseTimeout: .seconds(10))
        } catch {
            throw ContainerizationError(.internalError, message: "failed to subscribe to container events", cause: error)
        }
        guard let handle = response.fileHandle(key: .fd) else {
            throw ContainerizationError(.internalError, message: "the container events subscription carried no stream")
        }
        guard let nonce = response.string(key: .processNonce) else {
            close(handle.fileDescriptor)
            throw ContainerizationError(.internalError, message: "the container events subscription named no server process")
        }
        return ContainerEventSubscription(
            processNonce: nonce, cursor: response.uint64(key: .eventsCursor), gap: response.bool(key: .eventsGap),
            events: ContainerEventLines.events(from: handle.fileDescriptor))
    }

    /// Dial a port on the container via vsock.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: .containerDial)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))

        let response: XPCMessage
        do {
            response = try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial port \(port) on container",
                cause: error
            )
        }
        guard let fh = response.fileHandle(key: .fd) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    /// Copy a file or directory from the host into the container.
    ///
    /// - Parameters:
    ///   - copyUIDGID: what is copied belongs to the container's user, as `docker cp -a` has
    ///     it; otherwise each file keeps the owner its source names.
    ///   - noOverwriteDirNonDir: have the guest refuse replacing a directory with a
    ///     non-directory or the reverse, including entries inside an archive.
    ///   - copyAsArchive: preserve explicit archive-upload replacement semantics.
    ///     Native file copies default to protecting directories and final symlinks.
    ///   - requester: who this copy is for, as `create` takes it.
    public func copyIn(
        id: String, source: String, destination: String, mode: UInt32 = 0o644, createParents: Bool = true, copyUIDGID: Bool = false, noOverwriteDirNonDir: Bool = false,
        copyAsArchive: Bool = false,
        requester: String? = nil
    ) async throws {
        let request = XPCMessage(route: .containerCopyIn)
        Self.setRequester(requester, on: request)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .fileMode, value: UInt64(mode))
        request.set(key: .createParents, value: createParents)
        request.set(key: .copyUIDGID, value: copyUIDGID)
        request.set(key: .noOverwriteDirNonDir, value: noOverwriteDirNonDir)
        request.set(key: .copyAsArchive, value: copyAsArchive)

        do {
            try await xpcSend(message: request, timeout: Self.grantAwareTimeout + .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy into container \(id)",
                cause: error
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// - Parameters:
    ///   - requester: who this copy is for, as `create` takes it.
    ///   - recordOwners: keep each copied file's owner in the container on it, as
    ///     `CopyOwner.recorded(at:)` reads it, for an archive of the copy that carries them.
    public func copyOut(
        id: String, source: String, destination: String, createParents: Bool = true, requester: String? = nil, recordOwners: Bool = false
    ) async throws {
        let request = XPCMessage(route: .containerCopyOut)
        Self.setRequester(requester, on: request)
        request.set(key: .id, value: id)
        request.set(key: .sourcePath, value: source)
        request.set(key: .destinationPath, value: destination)
        request.set(key: .createParents, value: createParents)
        request.set(key: .recordCopyOwners, value: recordOwners)

        do {
            try await xpcSend(message: request, timeout: Self.grantAwareTimeout + .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy from container \(id)",
                cause: error
            )
        }
    }

    /// Get resource usage statistics for a container.
    public func stats(id: String) async throws -> ContainerStats {
        let request = XPCMessage(route: .containerStats)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcClient.send(request)
            guard let data = response.dataNoCopy(key: .statistics) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no statistics data returned"
                )
            }
            return try JSONDecoder().decode(ContainerStats.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get statistics for container \(id)",
                cause: error
            )
        }
    }

    public func export(id: String, archive: URL) async throws {
        let request = XPCMessage(route: .containerExport)
        request.set(key: .id, value: id)
        request.set(key: .archive, value: archive.absolutePath())

        do {
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to export container",
                cause: error
            )
        }
    }

    public func clean(id: String) async throws {
        let request = XPCMessage(route: .containerClean)
        request.set(key: .id, value: id)

        do {
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to clean container",
                cause: error
            )
        }
    }
}
