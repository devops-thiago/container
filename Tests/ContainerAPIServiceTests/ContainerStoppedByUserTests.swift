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

/// Whether a stopped container's last run was ended by a person, on a real containers service
/// whose runtime helpers run nothing: a stop records 143 or 137 as Docker does, and this is
/// what tells it from a process that failed with the same code.
@Suite(.timeLimit(.minutes(1)))
struct ContainerStoppedByUserTests {
    private func snapshot(_ service: ContainersService, _ id: String) async throws -> ContainerSnapshot {
        try #require(try await service.list().first { $0.id == id })
    }

    @Test("a stop is the person's, with the 143 it caused, and still is after the engine restarts")
    func stopIsByUser() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        #expect(try await snapshot(service, configuration.id).stoppedByUser == false)
        try await f.start(service, configuration.id)
        try await service.stop(id: configuration.id, options: .default)

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stoppedByUser == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == 143)
        #expect(reloaded.stoppedByUser == true)
    }

    @Test("a SIGKILL from a person is theirs, with 137")
    func killIsByUser() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        try await service.kill(id: configuration.id, processID: configuration.id, signal: "SIGKILL")

        let killed = try await snapshot(service, configuration.id)
        #expect(killed.exitCode == 137)
        #expect(killed.stoppedByUser == true)
    }

    @Test("a process that ends by itself is not stopped by anyone, whatever its code, here and after the engine restarts", arguments: [Int32(137), 1, 0])
    func exitByItselfIsNotByUser(code: Int32) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.lastRuntime?.exit(code)
        #expect(EventCollector.actions(await reader.take(3)) == ["create", "start", "die"])

        let exited = try await snapshot(service, configuration.id)
        #expect(exited.status == .stopped)
        #expect(exited.exitCode == code)
        #expect(exited.stoppedByUser == false)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == code)
        #expect(reloaded.stoppedByUser == false)
    }

    @Test("a start forgets the earlier stop: the next run's own end is the answer")
    func startResets() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        try await service.stop(id: configuration.id, options: .default)
        #expect(try await snapshot(service, configuration.id).stoppedByUser == true)

        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await f.start(service, configuration.id)
        let running = try await snapshot(service, configuration.id)
        #expect(running.status == .running)
        #expect(running.stoppedByUser == false)
        f.lastRuntime?.exit(1)
        #expect(EventCollector.actions(await reader.take(2)) == ["start", "die"])
        let crashed = try await snapshot(service, configuration.id)
        #expect(crashed.exitCode == 1)
        #expect(crashed.stoppedByUser == false)
    }

    @Test("a restart under the policy is no one's stop; a stop of the restarted run is")
    func restartPolicyRestart() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(restartPolicy: .always)
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.lastRuntime?.exit(1)
        #expect(EventCollector.actions(await reader.take(4)) == ["create", "start", "die", "start"])

        let restarted = try await snapshot(service, configuration.id)
        #expect(restarted.status == .running)
        #expect(restarted.restartCount == 1)
        #expect(restarted.stoppedByUser == false)
        try await service.stop(id: configuration.id, options: .default)
        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stoppedByUser == true)
    }

    @Test("a crash waiting out its restart delay is no one's stop; a stop that ends the wait is")
    func stopDuringRestartDelay() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        // The delay lasts until the stop cancels it.
        let service = try f.service(restartDelay: { _ in try await Task.sleep(for: .seconds(600)) })
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(restartPolicy: .always)
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.lastRuntime?.exit(1)
        #expect(EventCollector.actions(await reader.take(3)) == ["create", "start", "die"])

        let waiting = try await snapshot(service, configuration.id)
        #expect(waiting.status == .restarting)
        #expect(waiting.exitCode == 1)
        #expect(waiting.stoppedByUser == false)
        try await service.stop(id: configuration.id, options: .default)
        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 1)
        #expect(stopped.stoppedByUser == true)
    }

    @Test("a stop as the engine goes down is not a person's")
    func engineShutdownStopIsNotByUser() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        await service.beginEngineShutdown()
        try await service.stop(id: configuration.id, options: ContainerStopOptions(timeoutInSeconds: 5, signal: nil, engineShutdown: true))

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stoppedByUser == false)
    }
}
