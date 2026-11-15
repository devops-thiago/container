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
import Logging
import Synchronization
import Testing

@testable import ContainerCluster

/// The stage of a start that points the nodes at the control plane's address: its order,
/// its one deadline, and that a node command which does not end cannot hold the start.
struct FollowControlPlaneTests {
    private final class Record: Sendable {
        private let state = Mutex<(events: [String], deadlines: [ContinuousClock.Instant])>(([], []))
        var events: [String] { state.withLock { $0.events } }
        var deadlines: [ContinuousClock.Instant] { state.withLock { $0.deadlines } }
        func note(_ event: String, _ deadline: ContinuousClock.Instant? = nil) {
            state.withLock {
                $0.events.append(event)
                if let deadline { $0.deadlines.append(deadline) }
            }
        }
    }

    private let log = Logger(label: "follow-control-plane-tests")

    private func operations(
        _ record: Record, address: String? = "192.168.65.2",
        run: @escaping @Sendable (String, String, ContinuousClock.Instant) async throws -> (code: Int32, output: String) = { _, _, _ in (0, "") }
    ) -> ClusterHelper.FollowOperations {
        .init(
            address: { address },
            waitForAPIServer: { record.note("api", $0) },
            run: { node, script, deadline in
                record.note("run \(node)", deadline)
                return try await run(node, script, deadline)
            })
    }

    @Test func controlPlaneFirstThenEachWorkerUnderOneDeadline() async throws {
        let record = Record()
        let scripts = Mutex<[String: String]>([:])
        try await ClusterHelper.followControlPlane(
            name: "dev", workers: ["dev-worker-1", "dev-worker-2"], log: log,
            operations: operations(record) { node, script, _ in
                scripts.withLock { $0[node] = script }
                return (0, "")
            })
        #expect(record.events == ["api", "run dev", "run dev-worker-1", "run dev-worker-2"])
        #expect(Set(record.deadlines).count == 1)
        #expect(scripts.withLock { $0["dev"] } == ClusterHelper.controlPlaneEndpointScript(address: "192.168.65.2"))
        #expect(scripts.withLock { $0["dev-worker-1"] } == ClusterHelper.workerEndpointScript(address: "192.168.65.2"))
    }

    @Test func nodeCommandThatFailsFailsTheStartWithWhatItSaid() async throws {
        let record = Record()
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.followControlPlane(
                name: "dev", workers: ["dev-worker-1"], log: log,
                operations: operations(record) { _, _, _ in (1, "The connection to the server was refused") })
        }
        #expect(failure?.message.contains("was refused") == true)
        #expect(record.events == ["api", "run dev"])
    }

    @Test func controlPlaneWithNoAddressFailsBeforeAnyCommand() async throws {
        let record = Record()
        await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.followControlPlane(name: "dev", workers: [], log: log, operations: operations(record, address: nil))
        }
        #expect(record.events.isEmpty)
    }

    /// The budget is spent while the API server is waited for: no node command is started.
    @Test func budgetSpentBeforeTheNodesIsATimeout() async throws {
        let record = Record()
        let clock = Mutex(ContinuousClock.now)
        var operations = operations(record)
        operations.waitForAPIServer = { deadline in
            record.note("api", deadline)
            clock.withLock { $0 = deadline }
        }
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.followControlPlane(
                name: "dev", workers: ["dev-worker-1"], log: log, operations: operations, now: { clock.withLock { $0 } })
        }
        #expect(failure?.code == .timeout)
        #expect(record.events == ["api"])
    }

    /// A command that answers after the budget does not count, whatever it answered: with no
    /// worker after it, nothing else would notice.
    @Test func answerAfterTheBudgetIsATimeout() async throws {
        let record = Record()
        let clock = Mutex(ContinuousClock.now)
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.followControlPlane(
                name: "dev", workers: [], log: log,
                operations: operations(record) { _, _, deadline in
                    clock.withLock { $0 = deadline }
                    return (0, "changed kube-proxy")
                }, now: { clock.withLock { $0 } })
        }
        #expect(failure?.code == .timeout)
        #expect(record.events == ["api", "run dev"])
    }

    /// The node's side of a command that never ends and keeps its stdout open.
    private final class Hung: Sendable {
        private let state = Mutex<(stdout: Int32, kills: Int)>((-1, 0))
        private let started: AsyncStream<Void>
        private let start: AsyncStream<Void>.Continuation
        private let killed: AsyncStream<Void>
        private let kill: AsyncStream<Void>.Continuation
        init() {
            (started, start) = AsyncStream.makeStream()
            (killed, kill) = AsyncStream.makeStream()
        }
        var kills: Int { state.withLock { $0.kills } }
        func begin(_ stdout: FileHandle) {
            state.withLock { $0.stdout = dup(stdout.fileDescriptor) }
            start.yield()
        }
        func begun() async { for await _ in started { return } }
        func receiveKill() {
            state.withLock {
                $0.kills += 1
                if $0.stdout >= 0 { close($0.stdout) }
                $0.stdout = -1
            }
            kill.yield()
        }
        func ended() async { for await _ in killed { return } }

        /// What `execCapture` does with the command, the engine's requests stood in for.
        func run(deadline: ContinuousClock.Instant) async throws -> (code: Int32, output: String) {
            try await ClusterHelper.capture(
                deadline: deadline,
                launch: { stdout in
                    self.begin(stdout)
                    return { [deadline] in
                        try await Task.sleep(until: deadline, clock: .continuous)
                        throw ContainerizationError(.timeout, message: "process request deadline expired")
                    }
                },
                kill: { self.receiveKill() })
        }
    }

    @Test("a node command that never ends is killed at the stage's deadline and the start fails", .timeLimit(.minutes(1)))
    func hungCommandEndsAtTheDeadline() async throws {
        let record = Record()
        let hung = Hung()
        let began = ContinuousClock.now
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.followControlPlane(
                name: "dev", workers: ["dev-worker-1"], log: log,
                operations: operations(record) { _, _, deadline in try await hung.run(deadline: deadline) },
                budget: .milliseconds(300))
        }
        #expect(failure?.code == .timeout)
        #expect(ContinuousClock.now - began < .seconds(10))
        await hung.ended()
        #expect(hung.kills == 1)
        #expect(record.events == ["api", "run dev"])
    }

    @Test("a start cancelled during a node command returns at once and kills the command", .timeLimit(.minutes(1)))
    func cancelledDuringACommand() async throws {
        let record = Record()
        let hung = Hung()
        let operations = operations(record) { _, _, deadline in try await hung.run(deadline: deadline) }
        let log = log
        let start = Task {
            try await ClusterHelper.followControlPlane(name: "dev", workers: ["dev-worker-1"], log: log, operations: operations, budget: .seconds(600))
        }
        await hung.begun()
        let cancelledAt = ContinuousClock.now
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(10))
        await hung.ended()
        #expect(hung.kills == 1)
        #expect(record.events == ["api", "run dev"])
    }
}
