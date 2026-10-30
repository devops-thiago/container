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

import ContainerPersistence
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import MachineAPIClient

public struct MachinesHarness: Sendable {
    let service: MachinesService

    public init(service: MachinesService) {
        self.service = service
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let machineConfig = message.dataNoCopy(key: MachineKeys.machineConfig.rawValue)
        guard let machineConfig else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container machine configuration cannot be empty"
            )
        }

        let bootConfigData = message.dataNoCopy(key: MachineKeys.bootConfig.rawValue)
        guard let bootConfigData else {
            throw ContainerizationError(.invalidArgument, message: "bootConfig cannot be empty")
        }
        let bootConfig = try JSONDecoder().decode(MachineConfig.self, from: bootConfigData)

        let config = try JSONDecoder().decode(MachineConfiguration.self, from: machineConfig)

        try await service.create(configuration: config, bootConfig: bootConfig)
        return message.reply()
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.delete(id: id)
        return message.reply()
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let machines = try await service.list()
        let data = try JSONEncoder().encode(machines)

        let reply = message.reply()
        reply.set(key: MachineKeys.machines.rawValue, value: data)
        return reply
    }

    @Sendable
    public func getDefault(_ message: XPCMessage) async throws -> XPCMessage {
        let id = try await service.getDefault()

        let reply = message.reply()
        if let id {
            reply.set(key: MachineKeys.id.rawValue, value: id)
        }
        return reply
    }

    @Sendable
    public func setDefault(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.setDefault(id: id)

        return message.reply()
    }

    private func bootInputs(_ message: XPCMessage) throws -> (id: String?, env: [String: String], bookmarks: [Data]) {
        let id = message.string(key: MachineKeys.id.rawValue)
        let env =
            try message.dataNoCopy(key: MachineKeys.dynamicEnv.rawValue).map {
                try JSONDecoder().decode([String: String].self, from: $0)
            } ?? [:]
        let bookmarks =
            try message.dataNoCopy(key: MachineKeys.hostDirectoryBookmarks.rawValue).map {
                try JSONDecoder().decode([Data].self, from: $0)
            } ?? []
        return (id, env, bookmarks)
    }

    @Sendable
    public func boot(_ message: XPCMessage) async throws -> XPCMessage {
        let inputs = try bootInputs(message)
        let snapshot = try await service.boot(id: inputs.id, dynamicEnv: inputs.env, hostDirectoryBookmarks: inputs.bookmarks)
        let reply = message.reply()
        reply.set(key: MachineKeys.snapshot.rawValue, value: try JSONEncoder().encode(snapshot))
        return reply
    }

    @Sendable
    public func bootForSetup(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        let inputs = try bootInputs(message)
        let result = try await service.bootForSetup(id: inputs.id, dynamicEnv: inputs.env, hostDirectoryBookmarks: inputs.bookmarks)
        if case .started(_, let lease) = result {
            let service = self.service
            await session.onDisconnect { await service.stopAfterSetupDisconnect(lease) }
        }
        let reply = message.reply()
        reply.set(key: MachineKeys.bootResult.rawValue, value: try JSONEncoder().encode(result))
        return reply
    }

    @Sendable
    public func completeSetup(_ message: XPCMessage) async throws -> XPCMessage {
        let lease = try setupLease(message)
        let snapshot = try await service.completeSetup(lease)
        let reply = message.reply()
        reply.set(key: MachineKeys.snapshot.rawValue, value: try JSONEncoder().encode(snapshot))
        return reply
    }

    @Sendable
    public func stopSetup(_ message: XPCMessage) async throws -> XPCMessage {
        let stopped = try await service.stopSetup(setupLease(message))
        let reply = message.reply()
        reply.set(key: MachineKeys.stopped.rawValue, value: stopped)
        return reply
    }

    private func setupLease(_ message: XPCMessage) throws -> MachineSetupLease {
        guard let data = message.dataNoCopy(key: MachineKeys.setupLease.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "machine setup lease is required")
        }
        return try JSONDecoder().decode(MachineSetupLease.self, from: data)
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.stop(id: id)
        return message.reply()
    }

    @Sendable
    public func inspect(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let snapshot = try await service.inspect(id: id)
        let data = try JSONEncoder().encode(snapshot)

        let reply = message.reply()
        reply.set(key: MachineKeys.snapshot.rawValue, value: data)
        return reply
    }

    @Sendable
    public func setConfig(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let bootConfigData = message.dataNoCopy(key: MachineKeys.bootConfig.rawValue)
        guard let bootConfigData else {
            throw ContainerizationError(.invalidArgument, message: "boot config cannot be empty")
        }
        let bootConfig = try JSONDecoder().decode(MachineConfig.self, from: bootConfigData)
        try await service.setConfig(id: id, bootConfig: bootConfig)
        return message.reply()
    }

    @Sendable
    public func logs(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: MachineKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }

        let fds = try await service.logs(id: id)
        let reply = message.reply()
        try reply.set(key: MachineKeys.logs.rawValue, value: fds)
        return reply
    }
}
