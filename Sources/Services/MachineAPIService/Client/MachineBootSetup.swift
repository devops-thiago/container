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

import ContainerXPC
import ContainerizationError
import Foundation

/// Authority for one unfinished setup, independent of a machine's reusable name.
/// The service revokes it when setup completes or the VM stops.
public struct MachineSetupLease: Codable, Equatable, Sendable {
    public let machineID: String
    public let containerID: String
    public let token: UUID

    public init(machineID: String, containerID: String, token: UUID) {
        self.machineID = machineID
        self.containerID = containerID
        self.token = token
    }
}

public enum MachineBootResult: Codable, Sendable {
    case started(snapshot: MachineSnapshot, lease: MachineSetupLease)
    case existing(snapshot: MachineSnapshot)
}

extension MachineClient {
    static func bootRequest(
        route: MachineRoutes, id: String?, dynamicEnv: [String: String], hostDirectoryBookmarks: [Data]
    ) throws -> XPCMessage {
        let request = XPCMessage(route: route.rawValue)
        if let id { request.set(key: MachineKeys.id.rawValue, value: id) }
        request.set(key: MachineKeys.dynamicEnv.rawValue, value: try JSONEncoder().encode(dynamicEnv))
        if !hostDirectoryBookmarks.isEmpty {
            request.set(key: MachineKeys.hostDirectoryBookmarks.rawValue, value: try JSONEncoder().encode(hostDirectoryBookmarks))
        }
        return request
    }

    func bootForSetup(id: String?, dynamicEnv: [String: String], hostDirectoryBookmarks: [Data]) async throws -> MachineBootResult {
        let request = try Self.bootRequest(
            route: .bootMachineForSetup, id: id, dynamicEnv: dynamicEnv, hostDirectoryBookmarks: hostDirectoryBookmarks)
        let response = try await xpcSend(message: request, timeout: nil, cancelOnTaskCancellation: true)
        guard let data = response.dataNoCopy(key: MachineKeys.bootResult.rawValue) else {
            throw ContainerizationError(.invalidState, message: "machine service did not return setup ownership")
        }
        return try JSONDecoder().decode(MachineBootResult.self, from: data)
    }

    func completeSetup(_ lease: MachineSetupLease) async throws -> MachineSnapshot {
        let request = XPCMessage(route: MachineRoutes.completeMachineSetup.rawValue)
        request.set(key: MachineKeys.setupLease.rawValue, value: try JSONEncoder().encode(lease))
        let response = try await xpcSend(message: request)
        guard let data = response.dataNoCopy(key: MachineKeys.snapshot.rawValue) else {
            throw ContainerizationError(.invalidState, message: "machine service did not confirm account setup")
        }
        return try JSONDecoder().decode(MachineSnapshot.self, from: data)
    }

    @discardableResult
    func stopSetup(_ lease: MachineSetupLease) async throws -> Bool {
        // A separate route prevents an older service from ignoring a new condition and
        // treating this rollback as an unconditional user Stop.
        let request = XPCMessage(route: MachineRoutes.stopMachineSetup.rawValue)
        request.set(key: MachineKeys.setupLease.rawValue, value: try JSONEncoder().encode(lease))
        let response = try await xpcSend(message: request, timeout: .seconds(30))
        return response.bool(key: MachineKeys.stopped.rawValue)
    }

    /// Prepare an actual boot once. Other callers wait for that setup, or use an already
    /// running VM without repeating account setup or acquiring rollback authority.
    public func bootAndPrepare(
        id: String?, dynamicEnv: [String: String] = [:], hostDirectoryBookmarks: [Data] = [],
        setupWaitTimeout: Duration = .seconds(300),
        setup: @Sendable (MachineSnapshot) async throws -> Void
    ) async throws -> MachineSnapshot {
        // Keep the setup owner on a dedicated connection: process exit or a lost boot
        // reply then revokes only its unfinished lease. Closing a waiting caller must
        // never close another caller's owner connection.
        let transport = setupClientFactory()
        defer { transport.close() }
        let client = MachineClient(xpcClient: transport, setupClientFactory: setupClientFactory)
        return try await client.prepareOnConnection(
            id: id, dynamicEnv: dynamicEnv, hostDirectoryBookmarks: hostDirectoryBookmarks,
            setupWaitTimeout: setupWaitTimeout, setup: setup)
    }

    private func prepareOnConnection(
        id: String?, dynamicEnv: [String: String], hostDirectoryBookmarks: [Data],
        setupWaitTimeout: Duration, setup: @Sendable (MachineSnapshot) async throws -> Void
    ) async throws -> MachineSnapshot {
        switch try await bootForSetup(id: id, dynamicEnv: dynamicEnv, hostDirectoryBookmarks: hostDirectoryBookmarks) {
        case .existing(let snapshot):
            return try await waitForSetup(snapshot, timeout: setupWaitTimeout)
        case .started(let snapshot, let lease):
            guard snapshot.status == .running, snapshot.setupPending,
                snapshot.id == lease.machineID, snapshot.containerId == lease.containerID
            else { throw ContainerizationError(.invalidState, message: "machine service returned inconsistent setup ownership") }
            do {
                try Task.checkCancellation()
                try await setup(snapshot)
                try Task.checkCancellation()
                return try await completeSetup(lease)
            } catch {
                // Cancellation of the caller must not prevent cleanup. The service checks
                // the lease under its lifecycle lock; a completed or replacement VM is safe.
                let cleanup = Task { try await self.stopSetup(lease) }
                _ = try? await cleanup.value
                throw error
            }
        }
    }

    private func waitForSetup(_ initial: MachineSnapshot, timeout: Duration) async throws -> MachineSnapshot {
        guard initial.status == .running, let containerID = initial.containerId else {
            throw ContainerizationError(.invalidState, message: "container machine is not running")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var snapshot = initial
        while snapshot.setupPending {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ContainerizationError(.timeout, message: "account setup for machine \(initial.id) has not finished; its VM was left running")
            }
            try await Task.sleep(for: min(.milliseconds(100), clock.now.duration(to: deadline)))
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { continue }
            do {
                snapshot = try await inspect(id: initial.id, responseTimeout: remaining, cancelOnTaskCancellation: true)
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            guard snapshot.status == .running, snapshot.containerId == containerID else {
                throw ContainerizationError(.invalidState, message: "machine \(initial.id) changed while waiting for account setup")
            }
        }
        return snapshot
    }
}
