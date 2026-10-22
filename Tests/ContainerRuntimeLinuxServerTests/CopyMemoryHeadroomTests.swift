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
        let slowSync: Bool

        init(before: String? = "83886080\n", failLift: Bool = false, slowSync: Bool = false) {
            self.before = before
            self.failLift = failLift
            self.slowSync = slowSync
        }

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
            if slowSync { try await Task.sleep(for: .seconds(3600)) }
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
        let control = FakeControl(slowSync: true)
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
    }

    @Test("the sync's time limit holds even when the sync does not end on cancellation", .timeLimit(.minutes(1)))
    func boundedEvenIfUncancellable() async throws {
        let clock = ManualClock()
        let release = Mutex(false)
        let outcome = Task {
            try await CopyMemoryHeadroom.within(.seconds(10), sleep: clock.sleep) {
                // A sync that ignores cancellation and ends only when released.
                while !release.withLock({ $0 }) {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        try await clock.waitForSleeps(1)
        clock.advance()
        #expect(try await outcome.value == false)
        release.withLock { $0 = true }
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
