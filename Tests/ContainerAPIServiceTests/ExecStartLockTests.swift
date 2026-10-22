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

@testable import ContainerAPIService

/// A guest that is out of memory or busy answers an exec late or never. Its start waited under
/// the engine-wide lock, so every create, start, exec and disk usage request of every other
/// container waited behind it, until the engine looked hung.
struct ExecStartLockTests {
    @Test("an exec whose guest never answers its start holds up no other container")
    func unansweredExecStartBlocksNothingElse() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(FakeRuntime.Behavior(holdStarts: ["stuck-exec"]), FakeRuntime.Behavior())
        let service = try f.service()

        let stuck = f.configuration().id
        try await f.create(service, f.configuration(id: stuck))
        try await f.start(service, stuck)
        let unresponsiveGuest = try #require(f.lastRuntime)
        let process = f.configuration().initProcess
        try await service.createProcess(id: stuck, processID: "stuck-exec", config: process, stdio: [nil, nil, nil])
        let stuckStart = Task { try await service.startProcess(id: stuck, processID: "stuck-exec") }
        #expect(await Self.within(.seconds(10)) { unresponsiveGuest.calls.contains("start stuck-exec held") })

        let finished = Mutex(false)
        let others = Task {
            let other = f.configuration().id
            try await f.create(service, f.configuration(id: other))
            try await f.start(service, other)
            try await service.createProcess(id: other, processID: "other-exec", config: process, stdio: [nil, nil, nil])
            try await service.startProcess(id: other, processID: "other-exec")
            _ = await service.calculateDiskUsage()
            finished.withLock { $0 = true }
        }
        let othersFinished = await Self.within(.seconds(10)) { finished.withLock { $0 } }

        // Answer the stuck start either way, so that a failure ends instead of hanging.
        unresponsiveGuest.releaseHeldStarts()
        try await stuckStart.value
        try await others.value
        #expect(othersFinished, "another container's create, start and exec, and disk usage, waited for the stuck exec")
        #expect(f.runtimeCount == 2)
    }

    @Test("an exec start still reaches its container's runtime and fails for a container that is not running")
    func execStartOutsideTheLockStillChecksTheContainer() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let id = f.configuration().id
        try await f.create(service, f.configuration(id: id))

        await #expect(throws: (any Error).self) {
            try await service.startProcess(id: id, processID: "exec-before-start")
        }
        await #expect(throws: (any Error).self) {
            try await service.startProcess(id: "no-such-container", processID: "exec")
        }

        try await f.start(service, id)
        let runtime = try #require(f.lastRuntime)
        try await service.startProcess(id: id, processID: "exec-after-start")
        #expect(runtime.starts == 2)
    }

    /// Whether `condition` holds within `limit`, polling without blocking a thread.
    private static func within(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
