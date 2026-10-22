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
        let failLift: Bool

        init(failLift: Bool = false) { self.failLift = failLift }

        func setMemoryHigh(_ value: String) async throws {
            calls.withLock { $0.append("memory.high=\(value)") }
            if failLift && value == "max" { throw POSIXError(.EACCES) }
        }

        func sync() async throws {
            calls.withLock { $0.append("sync") }
        }

        var recorded: [String] { calls.withLock { $0 } }
    }

    static let restore = "memory.high=83886080"

    /// Wait until `control` has recorded `count` calls.
    static func waitForCalls(_ control: FakeControl, _ count: Int) async throws {
        while control.recorded.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a copy runs with vminitd's limit lifted, and the limit goes back after a sync once the copy has settled", .timeLimit(.minutes(1)))
    func liftsAndRestores() async throws {
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(50))
        let control = FakeControl()
        let seen = try await headroom.withLifted(control) { control.recorded }
        #expect(seen == ["memory.high=max"])
        // Not straight away: the copy's pages are still being written back.
        #expect(control.recorded == ["memory.high=max"])
        #expect(await headroom.lifted)
        try await Self.waitForCalls(control, 3)
        #expect(control.recorded == ["memory.high=max", "sync", Self.restore])
        #expect(await !headroom.lifted)
        // The value put back is vminitd's own.
        #expect(CopyMemoryHeadroom.vminitdMemoryHigh == 80 * 1024 * 1024)
        #expect(CopyMemoryHeadroom.memoryHighPath == "/sys/fs/cgroup/vminitd/memory.high")
    }

    @Test("copies that overlap lift the limit once and put it back once, after the last", .timeLimit(.minutes(1)))
    func overlapping() async throws {
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(50))
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
        // The second copy has ended while the first runs: the limit stays lifted.
        try await Task.sleep(for: .milliseconds(200))
        #expect(control.recorded == ["memory.high=max"])
        releaseContinuation.yield(())
        try await first.value
        try await Self.waitForCalls(control, 3)
        #expect(control.recorded == ["memory.high=max", "sync", Self.restore])
    }

    @Test("a copy that starts while the last one settles keeps the limit lifted", .timeLimit(.minutes(1)))
    func restartBeforeRestore() async throws {
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(300))
        let control = FakeControl()
        try await headroom.withLifted(control) {}
        try await headroom.withLifted(control) {}
        try await Task.sleep(for: .milliseconds(150))
        #expect(control.recorded == ["memory.high=max"])
        try await Self.waitForCalls(control, 3)
        #expect(control.recorded == ["memory.high=max", "sync", Self.restore])
    }

    @Test("a copy runs even when the limit cannot be lifted, and nothing is put back", .timeLimit(.minutes(1)))
    func liftFails() async throws {
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(20))
        let control = FakeControl(failLift: true)
        let ran = try await headroom.withLifted(control) { true }
        #expect(ran)
        try await Task.sleep(for: .milliseconds(200))
        #expect(control.recorded == ["memory.high=max"])
        #expect(await !headroom.lifted)
    }

    @Test("a container that stops drops the pending restore", .timeLimit(.minutes(1)))
    func discard() async throws {
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(100))
        let control = FakeControl()
        try await headroom.withLifted(control) {}
        await headroom.discard()
        try await Task.sleep(for: .milliseconds(300))
        #expect(control.recorded == ["memory.high=max"])
    }

    @Test("a failed copy still puts the limit back", .timeLimit(.minutes(1)))
    func failedCopyRestores() async throws {
        struct CopyFailed: Error {}
        let headroom = CopyMemoryHeadroom(settleDelay: .milliseconds(20))
        let control = FakeControl()
        await #expect(throws: CopyFailed.self) {
            try await headroom.withLifted(control) { throw CopyFailed() }
        }
        try await Self.waitForCalls(control, 3)
        #expect(control.recorded == ["memory.high=max", "sync", Self.restore])
    }
}
