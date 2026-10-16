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
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

public struct ContainersHarness: Sendable {
    let log: Logging.Logger
    let service: ContainersService

    public init(service: ContainersService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        var filters = ContainerListFilters.all
        if let filterData = message.dataNoCopy(key: .listFilters) {
            filters = try JSONDecoder().decode(ContainerListFilters.self, from: filterData)
        }
        let containers = try await service.list(filters: filters)
        let data = try JSONEncoder().encode(containers)

        let reply = message.reply()
        reply.set(key: .containers, value: data)
        return reply
    }

    /// Who a request is for, as a folder-permission panel names it: what the client said, when
    /// it acts for another process (the Docker API agent names the Docker client), or else the
    /// process on the other end of the XPC connection, so a `container run -v` names
    /// `container`. Display only, and sanitized either way.
    ///
    /// - Parameter name: how a process's name is found; the system's by default.
    static func requester(
        of message: XPCMessage,
        peerPID: pid_t,
        name: (pid_t) -> String? = GrantRequester.processName(of:)
    ) -> String? {
        if let stated = GrantRequester.sanitized(message.string(key: .hostDirectoryRequester)) {
            return stated
        }
        return GrantRequester.describe(pid: peerPID, name: name)
    }

    /// A route that takes the requester from the peer when the message names none.
    public func bootstrap(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        try await bootstrap(message, peerPID: session.peerPID)
    }

    public func create(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        try await create(message, peerPID: session.peerPID)
    }

    public func copyIn(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        try await copyIn(message, peerPID: session.peerPID)
    }

    public func copyOut(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        try await copyOut(message, peerPID: session.peerPID)
    }

    @Sendable
    public func bootstrap(_ message: XPCMessage, peerPID: pid_t = 0) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let stdio = message.stdio()

        let data = message.dataNoCopy(key: .dynamicEnv)
        let env = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

        var bookmarks: [Data] = []
        if let bdata = message.dataNoCopy(key: .hostDirectoryBookmarks) {
            bookmarks = try JSONDecoder().decode([Data].self, from: bdata)
        }

        try await service.bootstrap(
            id: id, stdio: stdio, dynamicEnv: env, hostDirectoryBookmarks: bookmarks,
            requester: Self.requester(of: message, peerPID: peerPID))
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        try await service.stop(
            id: id,
            options: stopOptions,
            requiredLabels: try message.requiredLabels(),
            expectedIncarnation: message.string(key: .expectedIncarnation))
        return message.reply()
    }

    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }

        let port = message.uint64(key: .port)
        let fh = try await service.dial(id: id, port: UInt32(port))
        let reply = message.reply()
        reply.setFileHandle(fh)

        return reply
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let exitStatus = try await service.wait(id: id, processID: processID)
        let reply = message.reply()
        reply.set(key: .exitCode, value: Int64(exitStatus.exitCode))
        reply.set(key: .exitedAt, value: exitStatus.exitedAt)
        return reply
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let width = message.uint64(key: .width)
        let height = message.uint64(key: .height)
        try await service.resize(
            id: id,
            processID: processID,
            size: Terminal.Size(width: UInt16(width), height: UInt16(height))
        )

        return message.reply()
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        try await service.kill(
            id: id,
            processID: processID,
            signal: try message.signal()
        )
        return message.reply()
    }

    @Sendable
    public func create(_ message: XPCMessage, peerPID: pid_t = 0) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .containerConfig)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container configuration cannot be empty"
            )
        }
        let kdata = message.dataNoCopy(key: .kernel)
        guard let kdata else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel cannot be empty"
            )
        }
        let odata = message.dataNoCopy(key: .containerOptions)
        var options: ContainerCreateOptions = .default
        if let odata {
            options = try JSONDecoder().decode(ContainerCreateOptions.self, from: odata)
        }
        let config = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        guard ManagedContainer.nameValid(config.id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(config.id) is not a valid container ID")
        }
        let kernel = try JSONDecoder().decode(Kernel.self, from: kdata)

        let initImage = message.string(key: .initImage)
        let runtimeData = message.dataNoCopy(key: .runtimeData)
        // A malformed bookmark blob is the embedder's bug, not the user's: fail the create
        // with the decode error rather than starting a container whose mounts cannot work.
        var bookmarks: [Data] = []
        if let bdata = message.dataNoCopy(key: .hostDirectoryBookmarks) {
            bookmarks = try JSONDecoder().decode([Data].self, from: bdata)
        }

        let requestedIncarnation = message.string(key: .expectedIncarnation)
        if let requestedIncarnation, UUID(uuidString: requestedIncarnation) == nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "container incarnation must be a UUID")
        }
        let incarnation = try await service.create(
            configuration: config, kernel: kernel, options: options, initImage: initImage,
            runtimeData: runtimeData, hostDirectoryBookmarks: bookmarks,
            incarnation: requestedIncarnation, requester: Self.requester(of: message, peerPID: peerPID))
        let reply = message.reply()
        reply.set(key: .expectedIncarnation, value: incarnation)
        return reply
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        let config = try message.processConfig()
        let stdio = message.stdio()

        try await service.createProcess(
            id: id,
            processID: processID,
            config: config,
            stdio: stdio
        )

        return message.reply()
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        try await service.startProcess(
            id: id,
            processID: processID,
        )

        return message.reply()
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let forceDelete = message.bool(key: .forceDelete)
        try await service.delete(
            id: id,
            force: forceDelete,
            requiredLabels: try message.requiredLabels(),
            expectedIncarnation: message.string(key: .expectedIncarnation))
        return message.reply()
    }

    @Sendable
    public func diskUsage(_ message: XPCMessage) async throws -> XPCMessage {
        guard let containerId = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(containerId) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(containerId) is not a valid container ID")
        }

        let size = try await service.containerDiskUsage(id: containerId)

        let reply = message.reply()
        reply.set(key: .containerSize, value: size)
        return reply
    }

    /// The container's writable size; the reply leaves it out when the engine cannot tell.
    @Sendable
    public func writableSize(_ message: XPCMessage) async throws -> XPCMessage {
        guard let containerId = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(containerId) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(containerId) is not a valid container ID")
        }

        let reply = message.reply()
        if let size = try await service.containerWritableSize(id: containerId) {
            reply.set(key: .containerWritableSize, value: size)
        }
        return reply
    }

    @Sendable
    public func logs(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let fds = try await service.logs(id: id)
        let reply = message.reply()
        try reply.set(key: .logs, value: fds)
        return reply
    }

    /// A subscription to container events: the read end of a pipe the service writes each
    /// event to as one JSON line, with where the stream starts and whether a reconnecting
    /// subscriber missed events it cannot have replayed.
    @Sendable
    public func events(_ message: XPCMessage) async throws -> XPCMessage {
        var since: ContainerEventCursor?
        if let nonce = message.string(key: .processNonce), let sequence = message.uint64IfPresent(key: .eventsSince) {
            since = ContainerEventCursor(processNonce: nonce, sequence: sequence)
        }
        let subscription = try service.events.subscribe(since: since)
        let reply = message.reply()
        // Passes the descriptor on and closes this process's copy of it.
        reply.set(key: .fd, value: subscription.handle)
        reply.set(key: .processNonce, value: subscription.processNonce)
        reply.set(key: .eventsCursor, value: subscription.cursor)
        reply.set(key: .eventsGap, value: subscription.gap)
        return reply
    }

    /// Set labels on a container, of the keys the service lets change.
    @Sendable
    public func updateLabels(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        guard let data = message.dataNoCopy(key: .containerLabels) else {
            throw ContainerizationError(.invalidArgument, message: "labels cannot be empty")
        }
        let labels: [String: String]
        do {
            labels = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "labels are not a string map", cause: error)
        }
        try await service.updateLabels(id: id, labels: labels, expectedIncarnation: message.string(key: .expectedIncarnation))
        return message.reply()
    }

    @Sendable
    public func copyIn(_ message: XPCMessage, peerPID: pid_t = 0) async throws -> XPCMessage {
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard let sourcePath = message.string(key: .sourcePath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "source path cannot be empty"
            )
        }
        guard let destinationPath = message.string(key: .destinationPath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "destination path cannot be empty"
            )
        }
        let mode = UInt32(message.uint64(key: .fileMode))
        let createParents = message.bool(key: .createParents)

        try await service.copyIn(
            id: id, source: sourcePath, destination: destinationPath, mode: mode, createParents: createParents,
            requester: Self.requester(of: message, peerPID: peerPID))
        return message.reply()
    }

    @Sendable
    public func copyOut(_ message: XPCMessage, peerPID: pid_t = 0) async throws -> XPCMessage {
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard let sourcePath = message.string(key: .sourcePath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "source path cannot be empty"
            )
        }
        guard let destinationPath = message.string(key: .destinationPath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "destination path cannot be empty"
            )
        }

        let createParents = message.bool(key: .createParents)

        try await service.copyOut(
            id: id, source: sourcePath, destination: destinationPath, createParents: createParents,
            requester: Self.requester(of: message, peerPID: peerPID))
        return message.reply()
    }

    @Sendable
    public func stats(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let stats = try await service.stats(id: id)
        let data = try JSONEncoder().encode(stats)
        let reply = message.reply()
        reply.set(key: .statistics, value: data)
        return reply
    }

    @Sendable
    public func export(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let archive = message.string(key: .archive)
        guard let archive else {
            throw ContainerizationError(
                .invalidArgument,
                message: "archive cannot be empty"
            )
        }
        let archiveUrl = URL(fileURLWithPath: archive)

        try await service.exportRootfs(id: id, archive: archiveUrl)
        return message.reply()
    }

    @Sendable
    public func clean(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }

        try await service.clean(id: id)
        return message.reply()
    }
}

extension XPCMessage {
    /// The labels a stop or delete insists on, or nil when the caller made no demand.
    func requiredLabels() throws -> [String: String]? {
        guard let data = data(key: .requiredLabels) else { return nil }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "required labels are not a string map", cause: error)
        }
    }
}
