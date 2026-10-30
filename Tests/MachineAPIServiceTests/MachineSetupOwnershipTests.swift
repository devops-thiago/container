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

import ContainerizationError
import Foundation
import Synchronization
import Testing

@testable import MachineAPIClient
@testable import MachineAPIService

struct MachineSetupOwnershipTests {
    private enum SetupFailure: Error { case refused }

    private func fixture(holdInspections: Bool = false, holdBootReply: Bool = false, _ body: (MachineSetupFixture) async throws -> Void) async throws {
        let f = try MachineSetupFixture(holdInspections: holdInspections, holdBootReply: holdBootReply)
        do {
            try await f.ready()
            try await body(f)
        } catch {
            await f.close()
            throw error
        }
        await f.close()
    }

    @Test func existingVMDoesNotRepeatSetupOrAcquireRollbackAuthority() async throws {
        try await fixture { f in
            try Data("1\n".utf8).write(to: URL(fileURLWithPath: f.bundle.path.appending(MachineBundle.initializedFile).string))
            let original = try await f.client.boot(id: "fixture")
            #expect(original.initialized)
            let invoked = Mutex(false)
            var reused: MachineSnapshot?
            do {
                reused = try await f.client.bootAndPrepare(id: "fixture") { _ in
                    invoked.withLock { $0 = true }
                    throw SetupFailure.refused
                }
            } catch { Issue.record("opening the existing VM unexpectedly ran failing setup: \(error)") }
            #expect(!invoked.withLock { $0 })
            #expect(reused?.containerId == original.containerId)
            #expect(try await f.client.inspect(id: "fixture").status == .running)
            #expect(await f.runtime.stops.isEmpty)
        }
    }

    @Test func setupFailureStopsOnlyItsNewVMAndNextAttemptStillRunsSetup() async throws {
        try await fixture { f in
            await #expect(throws: SetupFailure.self) {
                try await f.client.bootAndPrepare(id: "fixture") { _ in throw SetupFailure.refused }
            }
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
            #expect(await f.runtime.stops.count == 1)
            let setups = Mutex(0)
            let ready = try await f.client.bootAndPrepare(id: "fixture") { _ in setups.withLock { $0 += 1 } }
            #expect(ready.status == .running)
            #expect(!ready.setupPending)
            #expect(setups.withLock { $0 } == 1)
            _ = try await f.client.bootAndPrepare(id: "fixture") { _ in setups.withLock { $0 += 1 } }
            #expect(setups.withLock { $0 } == 1)
            // An explicit user Stop remains unconditional. A real new boot runs setup again.
            try await f.client.stop(id: "fixture")
            let rebooted = try await f.client.bootAndPrepare(id: "fixture") { _ in setups.withLock { $0 += 1 } }
            #expect(rebooted.containerId != ready.containerId)
            #expect(setups.withLock { $0 } == 2)
        }
    }

    @Test func completionRevokesRollbackAndOldLeaseCannotStopReplacement() async throws {
        try await fixture { f in
            guard case .started(let pending, let lease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected setup ownership")
                return
            }
            #expect(pending.setupPending)
            let forged = MachineSetupLease(machineID: lease.machineID, containerID: lease.containerID, token: UUID())
            #expect(try await !f.client.stopSetup(forged))
            await #expect(throws: (any Error).self) { try await f.client.completeSetup(forged) }
            #expect(try await f.client.inspect(id: "fixture").setupPending)
            let ready = try await f.client.completeSetup(lease)
            #expect(!ready.setupPending)
            #expect(try await !f.client.stopSetup(lease))
            #expect(await f.runtime.stops.isEmpty)
            try await f.client.stop(id: "fixture")
            guard case .started(let replacement, let nextLease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected replacement ownership")
                return
            }
            #expect(nextLease != lease)
            #expect(replacement.containerId != pending.containerId)
            #expect(try await !f.client.stopSetup(lease))
            #expect(try await f.client.inspect(id: "fixture").containerId == replacement.containerId)
            #expect(try await f.client.stopSetup(nextLease))
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
        }
    }

    @Test func followerTimeoutDoesNotProvisionOrStopOwnersVM() async throws {
        try await fixture { f in
            guard case .started(let pending, let lease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            let called = Mutex(false)
            await #expect(throws: (any Error).self) {
                try await f.client.bootAndPrepare(id: "fixture", setupWaitTimeout: .milliseconds(150)) { _ in called.withLock { $0 = true } }
            }
            #expect(!called.withLock { $0 })
            #expect(await f.runtime.stops.isEmpty)
            #expect(try await f.client.inspect(id: "fixture").containerId == pending.containerId)
            _ = try await f.client.completeSetup(lease)
            _ = try await f.client.bootAndPrepare(id: "fixture") { _ in called.withLock { $0 = true } }
            #expect(!called.withLock { $0 })
        }
    }
    private func event(_ stream: AsyncStream<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var events = stream.makeAsyncIterator()
                guard await events.next() != nil else { throw SetupFailure.refused }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ContainerizationError(.timeout, message: "fixture did not reach expected lifecycle step")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    @Test func concurrentShellWaitsForOwnerAndDoesNotRepeatSetup() async throws {
        try await fixture { f in
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let callbacks = Mutex(0)
            let owner = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in
                    callbacks.withLock { $0 += 1 }
                    entered.continuation.yield(())
                    var next = release.stream.makeAsyncIterator()
                    _ = await next.next()
                    try Task.checkCancellation()
                }
            }
            defer {
                release.continuation.finish()
                entered.continuation.finish()
                owner.cancel()
            }
            try await event(entered.stream)
            let follower = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in callbacks.withLock { $0 += 1 } }
            }
            defer { follower.cancel() }
            try await event(f.inspectionEvents)
            // The inspection proves the second caller reached the pending VM, before
            // allowing setup to finish. No scheduler delay is used to create the overlap.
            #expect(callbacks.withLock { $0 } == 1)
            release.continuation.yield(())
            let first = try await owner.value
            let second = try await follower.value
            #expect(first.containerId == second.containerId)
            #expect(!second.setupPending)
            #expect(callbacks.withLock { $0 } == 1)
            #expect(await f.runtime.stops.isEmpty)
        }
    }

    @Test func cancellingFollowerLeavesOwnersVMRunning() async throws {
        try await fixture { f in
            guard case .started(let pending, let lease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            let invoked = Mutex(false)
            let follower = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in invoked.withLock { $0 = true } }
            }
            defer { follower.cancel() }
            try await event(f.inspectionEvents)
            follower.cancel()
            await #expect(throws: CancellationError.self) { try await follower.value }
            #expect(!invoked.withLock { $0 })
            #expect(await f.runtime.stops.isEmpty)
            let retained = try await f.client.inspect(id: "fixture")
            #expect(retained.containerId == pending.containerId)
            #expect(retained.setupPending)
            _ = try await f.client.completeSetup(lease)
        }
    }

    @Test func cancellingOwnerStillRollsBackItsUnfinishedVM() async throws {
        try await fixture { f in
            let entered = AsyncStream<Void>.makeStream()
            let owner = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in
                    entered.continuation.yield(())
                    try await Task.sleep(for: .seconds(60))
                }
            }
            defer {
                entered.continuation.finish()
                owner.cancel()
            }
            try await event(entered.stream)
            owner.cancel()
            await #expect(throws: CancellationError.self) { try await owner.value }
            #expect(await f.runtime.stops.count == 1)
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
        }
    }

    @Test func waitingCallerDoesNotFollowOrStopAReplacementVM() async throws {
        try await fixture { f in
            _ = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: [])
            let called = Mutex(false)
            let follower = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in called.withLock { $0 = true } }
            }
            defer { follower.cancel() }
            try await event(f.inspectionEvents)
            try await f.client.stop(id: "fixture")
            let replacement = try await f.client.boot(id: "fixture")
            await #expect(throws: (any Error).self) { try await follower.value }
            #expect(!called.withLock { $0 })
            #expect(await f.runtime.stops.count == 1)
            let retained = try await f.client.inspect(id: "fixture")
            #expect(retained.status == .running)
            #expect(retained.containerId == replacement.containerId)
        }
    }

    @Test func rollbackCannotStopBackingContainerReplacedOutsideMachineService() async throws {
        try await fixture { f in
            guard case .started(let pending, let lease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            await f.runtime.replace(try #require(pending.containerId))
            await #expect(throws: (any Error).self) { try await f.client.stopSetup(lease) }
            #expect(await f.runtime.stops.isEmpty)
        }
    }

    @Test func cancellationAfterNoncooperativeSetupDoesNotCommitReadyState() async throws {
        try await fixture { f in
            let entered = AsyncStream<Void>.makeStream()
            let wait = AsyncStream<Void>.makeStream()
            let owner = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in
                    entered.continuation.yield(())
                    var next = wait.stream.makeAsyncIterator()
                    _ = await next.next()
                    // Deliberately return normally after cancellation, as an RPC-backed
                    // setup callback can do. The coordinator must check before completion.
                }
            }
            defer {
                entered.continuation.finish()
                wait.continuation.finish()
                owner.cancel()
            }
            try await event(entered.stream)
            owner.cancel()
            await #expect(throws: CancellationError.self) { try await owner.value }
            #expect(await f.runtime.stops.count == 1)
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
        }
    }

    @Test func cancellingFollowerReturnsWhileInspectResponseIsHeld() async throws {
        try await fixture(holdInspections: true) { f in
            guard case .started(_, let lease) = try await f.client.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            let finished = AsyncStream<Void>.makeStream()
            let follower = Task {
                defer { finished.continuation.yield(()) }
                return try await f.client.bootAndPrepare(id: "fixture") { _ in Issue.record("follower ran setup") }
            }
            defer {
                follower.cancel()
                finished.continuation.finish()
            }
            try await event(f.inspectionEvents)
            follower.cancel()
            try await event(finished.stream)
            await #expect(throws: CancellationError.self) { try await follower.value }
            #expect(await f.runtime.stops.isEmpty)
            // The same client remains usable and the original owner can finish.
            let ready = try await f.client.completeSetup(lease)
            #expect(ready.status == .running)
            #expect(!ready.setupPending)
            f.releaseInspections()
        }
    }

    @Test func staleExitForReusedBackingIDDoesNotClearCurrentMachine() async throws {
        try await fixture { f in
            let ready = try await f.client.bootAndPrepare(id: "fixture") { _ in }
            let containerID = try #require(ready.containerId)
            // A delayed event can carry the same short generated ID after reuse,
            // but cannot carry the current runtime's opaque incarnation.
            await f.service.handleMachineExit(id: "fixture", code: nil, containerID: containerID, incarnation: UUID().uuidString)
            let retained = try await f.client.inspect(id: "fixture")
            #expect(retained.containerId == containerID)
            #expect(retained.status == .running)
            #expect(await f.runtime.stops.isEmpty)
        }
    }

    @Test func losingSetupOwnerConnectionRollsBackOnlyItsUnfinishedVM() async throws {
        try await fixture { f in
            let (owner, connection) = f.additionalClient()
            defer { connection.close() }
            guard case .started = try await owner.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            connection.close()
            try await event(f.setupDisconnectEvents)
            #expect(await f.runtime.stops.count == 1)
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
        }
    }

    @Test func disconnectAfterCompletionDoesNotStopReadyVM() async throws {
        try await fixture { f in
            let (owner, connection) = f.additionalClient()
            defer { connection.close() }
            guard case .started(_, let lease) = try await owner.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: []) else {
                Issue.record("expected owner")
                return
            }
            let ready = try await owner.completeSetup(lease)
            connection.close()
            try await event(f.setupDisconnectEvents)
            #expect(await f.runtime.stops.isEmpty)
            let retained = try await f.client.inspect(id: "fixture")
            #expect(retained.status == .running)
            #expect(retained.containerId == ready.containerId)
        }
    }

    @Test func lateOwnerDisconnectCannotStopReplacementVM() async throws {
        try await fixture { f in
            let (owner, connection) = f.additionalClient()
            defer { connection.close() }
            _ = try await owner.bootForSetup(id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: [])
            try await f.client.stop(id: "fixture")
            guard
                case .started(_, let replacementLease) = try await f.client.bootForSetup(
                    id: "fixture", dynamicEnv: [:], hostDirectoryBookmarks: [])
            else {
                Issue.record("expected replacement owner")
                return
            }
            let replacement = try await f.client.completeSetup(replacementLease)
            connection.close()
            try await event(f.setupDisconnectEvents)
            #expect(await f.runtime.stops.count == 1)
            let retained = try await f.client.inspect(id: "fixture")
            #expect(retained.status == .running)
            #expect(retained.containerId == replacement.containerId)
        }
    }

    @Test func cancellationBeforeBootReplyCleansUpWithoutReceivingTheLease() async throws {
        try await fixture(holdBootReply: true) { f in
            let invoked = Mutex(false)
            let operation = Task {
                try await f.client.bootAndPrepare(id: "fixture") { _ in invoked.withLock { $0 = true } }
            }
            try await event(f.bootReplyEvents)
            operation.cancel()
            let watchdogFired = Mutex(false)
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                watchdogFired.withLock { $0 = true }
                f.releaseBootReplies()
            }
            defer { watchdog.cancel() }
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(!watchdogFired.withLock { $0 })
            try await event(f.setupDisconnectEvents)
            #expect(!invoked.withLock { $0 })
            #expect(await f.runtime.stops.count == 1)
            #expect(try await f.client.inspect(id: "fixture").status == .stopped)
        }
    }

}
