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

/// Whether a stopped container's last run ended because a stop or a kill was asked for it, on
/// a real containers service whose runtime helpers run nothing: a stop records 143 or 137 as
/// Docker does, and this is what tells it from a process that failed with the same code.
@Suite(.timeLimit(.minutes(1)))
struct ContainerStopRequestedTests {
    private func snapshot(_ service: ContainersService, _ id: String) async throws -> ContainerSnapshot {
        try #require(try await service.list().first { $0.id == id })
    }

    @Test("a stop is a requested end, with the 143 it caused, and still is after the engine restarts")
    func stopIsRequested() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        #expect(try await snapshot(service, configuration.id).stopRequested == false)
        try await f.start(service, configuration.id)
        try await service.stop(id: configuration.id, options: .default)

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stopRequested == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == 143)
        #expect(reloaded.stopRequested == true)
    }

    @Test("a SIGKILL is a requested end, with 137")
    func killIsRequested() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        try await service.kill(id: configuration.id, processID: configuration.id, signal: "SIGKILL")

        let killed = try await snapshot(service, configuration.id)
        #expect(killed.exitCode == 137)
        #expect(killed.stopRequested == true)
    }

    @Test("a process that ends by itself was not stopped, whatever its code, here and after the engine restarts", arguments: [Int32(137), 1, 0])
    func exitByItselfIsNotRequested(code: Int32) async throws {
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
        #expect(exited.stopRequested == false)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == code)
        #expect(reloaded.stopRequested == false)
    }

    @Test("a signal the process outlives does not make its later exit a requested one, here or after the engine restarts", arguments: [Int32(1), 137])
    func survivedSignalThenExitIsNotRequested(code: Int32) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await service.kill(id: configuration.id, processID: configuration.id, signal: "SIGUSR1")
        #expect(try await snapshot(service, configuration.id).status == .running)
        f.lastRuntime?.exit(code)
        #expect(EventCollector.actions(await reader.take(2)) == ["kill", "die"])

        let exited = try await snapshot(service, configuration.id)
        #expect(exited.exitCode == code)
        #expect(exited.stopRequested == false)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.stopRequested == false)
    }

    @Test("a signal whose exit shows it ended the process is a requested end", arguments: [("SIGTERM", Int32(143)), ("SIGUSR1", 138), ("SIGINT", 130)])
    func signalThatEndsIsRequested(signal: String, code: Int32) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await service.kill(id: configuration.id, processID: configuration.id, signal: signal)
        f.lastRuntime?.exit(code)
        #expect(EventCollector.actions(await reader.take(2)) == ["kill", "die"])

        let exited = try await snapshot(service, configuration.id)
        #expect(exited.exitCode == code)
        #expect(exited.stopRequested == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.stopRequested == true)
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
        #expect(try await snapshot(service, configuration.id).stopRequested == true)

        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await f.start(service, configuration.id)
        let running = try await snapshot(service, configuration.id)
        #expect(running.status == .running)
        #expect(running.stopRequested == false)
        f.lastRuntime?.exit(1)
        #expect(EventCollector.actions(await reader.take(2)) == ["start", "die"])
        let crashed = try await snapshot(service, configuration.id)
        #expect(crashed.exitCode == 1)
        #expect(crashed.stopRequested == false)
    }

    @Test("a restart under the policy is not a stop; a stop of the restarted run is")
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
        #expect(restarted.stopRequested == false)
        try await service.stop(id: configuration.id, options: .default)
        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stopRequested == true)
    }

    @Test("a crash waiting out its restart delay was not stopped; a stop that ends the wait is, after the engine restarts too")
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
        #expect(waiting.stopRequested == false)
        try await service.stop(id: configuration.id, options: .default)
        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 1)
        #expect(stopped.stopRequested == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.exitCode == 1)
        #expect(reloaded.stopRequested == true)
    }

    @Test("a stop as the engine goes down is a requested end, and unless-stopped still starts the container with the engine")
    func engineShutdownStopIsRequested() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration(restartPolicy: .unlessStopped)
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        // As the system shutdown service does it: the engine going down, then plain stops.
        await service.beginEngineShutdown()
        try await service.stop(id: configuration.id, options: .default)

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 143)
        #expect(stopped.stopRequested == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.stopRequested == true)
        // The restart policy's mark is untouched: this was not a person's stop.
        let record = ContainerResource.Bundle(path: f.containers.appendingPathComponent(configuration.id)).restartRecord
        #expect(record.stoppedByUser == false)
        #expect(RestartRules.startsWithEngine(policy: .unlessStopped, record: record))
    }

    @Test("a crash waiting out its restart delay when the engine goes down is down because of the engine")
    func engineShutdownDuringRestartDelay() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(restartDelay: { _ in try await Task.sleep(for: .seconds(600)) })
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(restartPolicy: .always)
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.lastRuntime?.exit(1)
        #expect(EventCollector.actions(await reader.take(3)) == ["create", "start", "die"])
        await service.beginEngineShutdown()

        let stopped = try await snapshot(service, configuration.id)
        #expect(stopped.status == .stopped)
        #expect(stopped.exitCode == 1)
        #expect(stopped.stopRequested == true)
        let reloaded = try await snapshot(try f.service(), configuration.id)
        #expect(reloaded.stopRequested == true)
    }
}
