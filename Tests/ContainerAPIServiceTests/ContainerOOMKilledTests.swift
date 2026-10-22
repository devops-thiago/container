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
import Foundation
import Testing

@testable import ContainerAPIService

/// Docker's `OOMKilled`, on a real containers service whose runtime helpers run nothing: the
/// runtime says whether the OOM killer acted in the container's cgroup during the run, and the
/// service keeps that with the exit, reports `oom` before `die`, and forgets it at the next start.
@Suite(.timeLimit(.minutes(1)))
struct ContainerOOMKilledTests {
    private func snapshot(_ service: ContainersService, _ id: String) async throws -> ContainerSnapshot {
        try #require(try await service.list().first { $0.id == id })
    }

    @Test("an OOM kill of the initial process ends the run with 137 and OOMKilled, here and after the engine restarts")
    func oomKillIsKept() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        #expect(try await snapshot(service, configuration.id).oomKilled == false)
        let runtime = try #require(f.lastRuntime)
        runtime.reportOOMKilled(true)
        runtime.exit(137)
        let events = await reader.take(4)
        #expect(EventCollector.actions(events) == ["create", "start", "oom", "die"])
        #expect(events[3].exitCode == 137)

        let exited = try await snapshot(service, configuration.id)
        #expect(exited.status == .stopped)
        #expect(exited.exitCode == 137)
        #expect(exited.oomKilled == true)
        // Killed by the kernel, not stopped: the restart policy treats it as a failure.
        #expect(exited.stopRequested == false)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == 137)
        #expect(reloaded.oomKilled == true)
    }

    @Test("a run with no OOM kill is not OOMKilled, whatever its code", arguments: [Int32(137), 1, 0])
    func noOOMKill(code: Int32) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let runtime = try #require(f.lastRuntime)
        runtime.reportOOMKilled(false)
        runtime.exit(code)
        #expect(EventCollector.actions(await reader.take(3)) == ["create", "start", "die"])
        #expect(await reader.settle().isEmpty)
        #expect(try await snapshot(service, configuration.id).oomKilled == false)
    }

    @Test("a stop after the OOM killer took another process still says OOMKilled, as Docker does")
    func stopAfterOOMKill() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        try #require(f.lastRuntime).reportOOMKilled(true)
        try await service.stop(id: configuration.id, options: .default)

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stopRequested == true)
        #expect(stopped.oomKilled == true)
    }

    @Test("under a restart policy an OOM kill restarts the container, and the new run starts with OOMKilled false")
    func restartAfterOOMKill() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(restartPolicy: .onFailure(maxRetries: nil))
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let runtime = try #require(f.lastRuntime)
        runtime.reportOOMKilled(true)
        runtime.exit(137)
        let events = await reader.take(5)
        #expect(EventCollector.actions(events) == ["create", "start", "oom", "die", "start"])
        #expect(f.runtimeCount == 2)

        let restarted = try await snapshot(service, configuration.id)
        #expect(restarted.status == .running)
        #expect(restarted.restartCount == 1)
        #expect(restarted.oomKilled == false)
    }

    @Test("a runtime that does not say leaves OOMKilled as the start set it")
    func runtimeThatDoesNotSay() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        try #require(f.lastRuntime).exit(137)
        #expect(EventCollector.actions(await reader.take(3)) == ["create", "start", "die"])
        let exited = try await snapshot(service, configuration.id)
        #expect(exited.exitCode == 137)
        #expect(exited.oomKilled == false)
    }
}
