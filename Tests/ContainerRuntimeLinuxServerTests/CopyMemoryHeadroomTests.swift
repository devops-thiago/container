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

import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct CopyMemoryHeadroomTests {
    /// vminitd as the headroom sees it: what was asked of it, in order.
    final class FakeControl: VminitdMemoryControl {
        let calls = Mutex<[String]>([])
        let before: String?
        let failLift: Bool
        /// Whether a sync ends only once `release` is set, ignoring cancellation.
        let heldSync: Bool
        let released = Mutex(false)

        init(before: String? = "83886080\n", failLift: Bool = false, heldSync: Bool = false) {
            self.before = before
            self.failLift = failLift
            self.heldSync = heldSync
        }

        func release() { released.withLock { $0 = true } }

        func memoryHigh() async throws -> String {
            calls.withLock { $0.append("read") }
            guard let before else { throw POSIXError(.EIO) }
            return before
        }

        func setMemoryHigh(_ value: String) async throws {
            calls.withLock { $0.append("memory.high=\(value)") }
            if failLift && value == "max" { throw POSIXError(.EACCES) }
        }

        func sync() async throws {
            calls.withLock { $0.append("sync") }
            while heldSync && !released.withLock({ $0 }) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        var recorded: [String] { calls.withLock { $0 } }
    }

    /// A clock the test moves: every sleep waits for the next `advance`. A cancelled sleep stops
    /// counting as pending the moment it is cancelled.
    final class ManualClock: Sendable {
        private let state = Mutex((generation: 0, sleepers: Set<UUID>()))

        var pending: Int { state.withLock { $0.sleepers.count } }

        var sleep: CopyMemoryHeadroom.Sleep {
            { [self] _ in
                let id = UUID()
                let start = state.withLock { state in
                    state.sleepers.insert(id)
                    return state.generation
                }
                defer { _ = state.withLock { $0.sleepers.remove(id) } }
                try await withTaskCancellationHandler {
                    while state.withLock({ $0.generation }) == start {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                } onCancel: {
                    _ = state.withLock { $0.sleepers.remove(id) }
                }
            }
        }

        /// Wake every sleep pending now.
        func advance() {
            state.withLock { state in
                state.generation += 1
                // Woken: no longer pending, even before each one sees it.
                state.sleepers.removeAll()
            }
        }

        /// Wait until exactly `count` sleeps are pending.
        func waitForSleeps(_ count: Int) async throws {
            while pending != count {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    static let lift = ["read", "memory.high=max"]

    /// Wait until `control` has recorded `count` calls.
    static func waitForCalls(_ control: FakeControl, _ count: Int) async throws {
        while control.recorded.count < count {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("a copy runs with vminitd's limit lifted; the value read before goes back after the settle wait and a sync", .timeLimit(.minutes(1)))
    func liftsAndRestores() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(before: "104857600\n")
        let seen = try await headroom.withLifted(control) { control.recorded }
        #expect(seen == Self.lift)
        // Not before the settle wait has passed: the copy's pages are still being written back.
        try await clock.waitForSleeps(1)
        #expect(control.recorded == Self.lift)
        #expect(await headroom.lifted)
        clock.advance()
        try await Self.waitForCalls(control, 4)
        #expect(control.recorded == Self.lift + ["sync", "memory.high=104857600"])
        #expect(await !headroom.lifted)
        #expect(CopyMemoryHeadroom.memoryHighPath == "/sys/fs/cgroup/vminitd/memory.high")
    }

    final class GatedLift: VminitdMemoryControl, Sendable {
        let state = Mutex((value: "104857600", writes: [String](), waiting: [CheckedContinuation<Void, Never>](), released: false))

        func memoryHigh() -> String { state.withLock { $0.value } }

        func setMemoryHigh(_ value: String) async {
            if value == "max" {
                await withCheckedContinuation { continuation in
                    let released = state.withLock {
                        $0.value = value
                        $0.writes.append(value)
                        if !$0.released { $0.waiting.append(continuation) }
                        return $0.released
                    }
                    if released { continuation.resume() }
                }
            } else {
                state.withLock {
                    $0.value = value
                    $0.writes.append(value)
                }
            }
        }

        func sync() {}

        func releaseWrites() {
            let waiting = state.withLock { state in
                defer { state.waiting.removeAll() }
                state.released = true
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    @Test("discarding a VM during its initial lift ignores a late reply", .timeLimit(.minutes(1)))
    func discardDuringInitialLift() async throws {
        let clock = ManualClock()
        let control = GatedLift()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let copy = Task { try await headroom.withLifted(control) {} }
        while control.state.withLock({ $0.waiting.isEmpty }) { await Task.yield() }
        await headroom.discard()
        control.releaseWrites()
        try await copy.value
        #expect(await !headroom.lifted)
        #expect(await !headroom.restoreScheduled)
    }

    @Test("copies joining an unfinished initial lift keep the original nondefault limit", .timeLimit(.minutes(1)))
    func overlappingInitialLift() async throws {
        let clock = ManualClock()
        let control = GatedLift()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let first = Task { try await headroom.withLifted(control) {} }
        while control.state.withLock({ $0.waiting.isEmpty }) { await Task.yield() }
        let second = Task { try await headroom.withLifted(control) {} }
        while await headroom.activeCopies != 2 { await Task.yield() }
        // Both calls have entered while the write's side effect is visible but its reply is held.
        // Give any wrongly independent second RPC a turn; correctness is checked by its effects.
        for _ in 0..<100 { await Task.yield() }
        #expect(control.state.withLock { $0.writes } == ["max"])
        control.releaseWrites()
        try await first.value
        try await second.value
        try await clock.waitForSleeps(1)
        clock.advance()
        while await headroom.lifted { await Task.yield() }
        #expect(control.state.withLock { $0.value } == "104857600")
        #expect(control.state.withLock { $0.writes } == ["max", "104857600"])
    }

    @Test("a limit that cannot be read goes back to vminitd's own 80 MiB", .timeLimit(.minutes(1)))
    func unreadable() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(before: nil)
        try await headroom.withLifted(control) {}
        try await clock.waitForSleeps(1)
        clock.advance()
        try await Self.waitForCalls(control, 4)
        #expect(control.recorded == Self.lift + ["sync", "memory.high=83886080"])
    }

    @Test("copies that overlap lift the limit once and put it back once, after the last", .timeLimit(.minutes(1)))
    func overlapping() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await headroom.withLifted(control) {
                startedContinuation.yield(())
                for await _ in release { break }
            }
        }
        for await _ in started { break }
        try await headroom.withLifted(control) {}
        // The second copy has ended while the first runs: nothing waits to put it back.
        #expect(clock.pending == 0)
        #expect(control.recorded == Self.lift)
        releaseContinuation.yield(())
        try await first.value
        try await clock.waitForSleeps(1)
        clock.advance()
        try await Self.waitForCalls(control, 4)
        #expect(control.recorded == Self.lift + ["sync", "memory.high=83886080"])
    }

    @Test("a copy that starts while the last one settles keeps the limit lifted", .timeLimit(.minutes(1)))
    func restartBeforeRestore() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl()
        try await headroom.withLifted(control) {}
        try await clock.waitForSleeps(1)
        try await headroom.withLifted(control) {}
        // The first wait was cancelled by the second copy, and the second copy's has begun.
        try await clock.waitForSleeps(1)
        #expect(control.recorded == Self.lift)
        clock.advance()
        try await Self.waitForCalls(control, 4)
        #expect(control.recorded == Self.lift + ["sync", "memory.high=83886080"])
    }

    @Test("a slow sync leaves the limit lifted, does not hold up the next copy, and is tried again", .timeLimit(.minutes(1)))
    func slowSync() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(heldSync: true)
        try await headroom.withLifted(control) {}
        try await clock.waitForSleeps(1)
        clock.advance()
        // The restore's sync is running and its time limit is pending.
        try await Self.waitForCalls(control, 3)
        try await clock.waitForSleeps(1)
        clock.advance()
        // The sync ran out of time: the limit stays lifted and a new settle wait begins.
        while await headroom.lifted && clock.pending == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        try await clock.waitForSleeps(1)
        #expect(control.recorded == Self.lift + ["sync"])
        #expect(await headroom.lifted)
        // A copy now starts at once, the limit still lifted.
        let ran = try await headroom.withLifted(control) { true }
        #expect(ran)
        #expect(control.recorded == Self.lift + ["sync"])
        control.release()
    }

    /// Wait until the headroom waits out a settle delay again, and nothing else sleeps.
    static func waitForSettle(_ headroom: CopyMemoryHeadroom, _ clock: ManualClock) async throws {
        while await !headroom.restoreScheduled || clock.pending != 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("a sync that never ends is asked for once, however many times the restore tries again", .timeLimit(.minutes(1)))
    func hungSyncIsNotRepeated() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(heldSync: true)
        try await headroom.withLifted(control) {}
        for _ in 0..<4 {
            // The settle delay, then the sync's time limit, which runs out.
            try await Self.waitForSettle(headroom, clock)
            clock.advance()
            try await Self.waitForCalls(control, 3)
            try await clock.waitForSleeps(1)
            clock.advance()
        }
        try await Self.waitForSettle(headroom, clock)
        #expect(control.recorded == Self.lift + ["sync"])
        #expect(await headroom.lifted)
        #expect(await headroom.syncRunning)
        // Once it ends, the next try asks for a sync of its own and puts the limit back.
        control.release()
        while await headroom.syncRunning {
            try await Task.sleep(for: .milliseconds(2))
        }
        clock.advance()
        try await Self.waitForCalls(control, 5)
        #expect(control.recorded == Self.lift + ["sync", "sync", "memory.high=83886080"])
        #expect(await !headroom.lifted)
    }

    @Test("a sync that began before the last copy ended does not count for that copy", .timeLimit(.minutes(1)))
    func staleSyncDoesNotCount() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(heldSync: true)
        try await headroom.withLifted(control) {}
        try await Self.waitForSettle(headroom, clock)
        clock.advance()
        try await Self.waitForCalls(control, 3)
        try await clock.waitForSleeps(1)
        clock.advance()
        // The sync ran out of time and is still running when another copy comes and goes.
        try await Self.waitForSettle(headroom, clock)
        try await headroom.withLifted(control) {}
        try await Self.waitForSettle(headroom, clock)
        clock.advance()
        // The restore waits for the running sync, which then ends in time.
        try await clock.waitForSleeps(1)
        control.release()
        try await Self.waitForSettle(headroom, clock)
        #expect(control.recorded == Self.lift + ["sync"])
        #expect(await headroom.lifted)
        clock.advance()
        try await Self.waitForCalls(control, 5)
        #expect(control.recorded == Self.lift + ["sync", "sync", "memory.high=83886080"])
    }

    @Test("a copy runs even when the limit cannot be lifted, and nothing is put back", .timeLimit(.minutes(1)))
    func liftFails() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl(failLift: true)
        let ran = try await headroom.withLifted(control) { true }
        #expect(ran)
        #expect(clock.pending == 0)
        #expect(control.recorded == Self.lift)
        #expect(await !headroom.lifted)
    }

    @Test("a container that stops drops the pending restore", .timeLimit(.minutes(1)))
    func discard() async throws {
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl()
        try await headroom.withLifted(control) {}
        try await clock.waitForSleeps(1)
        await headroom.discard()
        // The cancelled wait ends without a restore.
        try await clock.waitForSleeps(0)
        clock.advance()
        #expect(control.recorded == Self.lift)
        #expect(await !headroom.lifted)
    }

    @Test("a failed copy still puts the limit back", .timeLimit(.minutes(1)))
    func failedCopyRestores() async throws {
        struct CopyFailed: Error {}
        let clock = ManualClock()
        let headroom = CopyMemoryHeadroom(sleep: clock.sleep)
        let control = FakeControl()
        await #expect(throws: CopyFailed.self) {
            try await headroom.withLifted(control) { throw CopyFailed() }
        }
        try await clock.waitForSleeps(1)
        clock.advance()
        try await Self.waitForCalls(control, 4)
        #expect(control.recorded == Self.lift + ["sync", "memory.high=83886080"])
    }
}
