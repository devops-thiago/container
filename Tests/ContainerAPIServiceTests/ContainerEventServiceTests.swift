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
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging
import Synchronization
import Testing
import XPC

@testable import ContainerAPIClient
@testable import ContainerAPIService
@testable import container_apiserver

/// The events a real containers service writes as it makes each change: its own create,
/// start, exit, stop, kill, health, restart and delete, with runtime helpers that run nothing.
@Suite(.timeLimit(.minutes(1)))
struct ContainerEventServiceTests {
    @Test("create, start, die and destroy, in that order, each once, with the exit code")
    func lifecycle() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(labels: ["com.docker.compose.project": "demo"])
        let incarnation = try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.lastRuntime?.exit(3)
        let died = await reader.take(3)
        #expect(EventCollector.actions(died) == ["create", "start", "die"])
        #expect(died.last?.exitCode == 3)
        try await service.delete(id: configuration.id, force: false)
        let events = died + (await reader.take(1))
        #expect(EventCollector.actions(events) == ["create", "start", "die", "destroy"])
        #expect(events.map(\.sequence) == events.map(\.sequence).sorted())
        #expect(events.allSatisfy { $0.id == configuration.id && $0.incarnation == incarnation })
        #expect(events.allSatisfy { $0.labels["com.docker.compose.project"] == "demo" })
        // Nothing more: each change is said once.
        #expect(await reader.settle().isEmpty)
    }

    @Test("a process that exits as it starts: start, then die, never the other way round")
    func immediateExit() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(FakeRuntime.Behavior(exitOnStart: 0))
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["create", "start", "die"])
        #expect(events.last?.exitCode == 0)
    }

    @Test("a stop says kill, die with the exit the stop caused, then stop")
    func stopCarriesExitCode() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await service.stop(id: configuration.id, options: .default)
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["kill", "die", "stop"])
        #expect(events[0].attributes["signal"] == "SIGTERM")
        #expect(events[1].exitCode == 143)
        // And the snapshot keeps it, as inspect shows it.
        #expect(try await service.list().first?.exitCode == 143)
    }

    @Test("a helper that does not say how the process ended holds a stop up for a bounded time, and its die has no exit code")
    func stopWithoutExitIsBounded() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(FakeRuntime.Behavior(exitOnStop: nil))
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let clock = ContinuousClock()
        let began = clock.now
        try await service.stop(id: configuration.id, options: .default)
        #expect(clock.now - began < ContainersService.exitAfterEndTimeout + .seconds(3))
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["kill", "die", "stop"])
        #expect(events[1].exitCode == nil)
    }

    @Test("SIGKILL says kill and die with 137; another signal says kill alone and changes nothing a listing shows")
    func killEvents() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))

        // No change a listing shows, and an event all the same: events are written where the
        // change is made, not found by comparing listings.
        let before = try await service.list()
        try await service.kill(id: configuration.id, processID: configuration.id, signal: "SIGUSR1")
        let after = try await service.list()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let (was, now) = (String(decoding: try encoder.encode(before), as: UTF8.self), String(decoding: try encoder.encode(after), as: UTF8.self))
        #expect(was == now)
        let signalled = await reader.take(1)
        #expect(EventCollector.actions(signalled) == ["kill"])
        #expect(signalled.first?.attributes["signal"] == "SIGUSR1")
        #expect(await reader.settle().isEmpty)

        try await service.kill(id: configuration.id, processID: configuration.id, signal: "SIGKILL")
        let killed = await reader.take(2)
        #expect(EventCollector.actions(killed) == ["kill", "die"])
        #expect(killed.last?.exitCode == 137)
    }

    @Test("a forced delete of a running container says kill, die and destroy")
    func forcedDelete() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(FakeRuntime.Behavior(exitOnStop: 137))
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        try await service.delete(id: configuration.id, force: true)
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["kill", "die", "destroy"])
        #expect(events[1].exitCode == 137)
        #expect(await reader.settle().isEmpty)
    }

    @Test("a health status that changes is said; one that stays the same is not")
    func healthTransitions() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(
            FakeRuntime.Behavior(health: [
                HealthUpdate(health: ContainerHealth(status: .starting), generation: 1, finished: false),
                HealthUpdate(health: ContainerHealth(status: .healthy), generation: 2, finished: false),
                HealthUpdate(health: ContainerHealth(status: .healthy, failingStreak: 0), generation: 3, finished: false),
                HealthUpdate(health: ContainerHealth(status: .unhealthy, failingStreak: 3), generation: 4, finished: false),
            ]))
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(healthCheck: HealthCheckConfiguration(test: ["CMD", "true"]))
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let events = await reader.take(4)
        #expect(EventCollector.actions(events) == ["create", "start", "health_status", "health_status"])
        #expect(events.compactMap(\.health) == [.healthy, .unhealthy])
        #expect(await reader.settle().isEmpty)
    }

    @Test("a restart policy's restart says die then start, the same container throughout; without one there is no start")
    func restartPolicy() async throws {
        for policy in [ContainerConfiguration.RestartPolicy.always, .no] {
            let f = EventServiceFixture()
            defer { f.cleanup() }
            let service = try f.service()
            let reader = EventCollector(try f.hub.subscribe(since: nil))
            let configuration = f.configuration(restartPolicy: policy)
            let incarnation = try await f.create(service, configuration)
            try await f.start(service, configuration.id)
            f.lastRuntime?.exit(1)
            if policy == .always {
                let events = await reader.take(4)
                #expect(EventCollector.actions(events) == ["create", "start", "die", "start"])
                #expect(events[2].exitCode == 1)
                #expect(events.allSatisfy { $0.incarnation == incarnation })
                #expect(f.runtimeCount == 2)
            } else {
                let events = await reader.take(3)
                #expect(EventCollector.actions(events) == ["create", "start", "die"])
                #expect(await reader.settle().isEmpty)
            }
        }
    }

    @Test("a start that fails says nothing, as Docker says nothing; the next one that works says start")
    func failedStart() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        f.failNextLaunch.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await f.start(service, configuration.id) }
        #expect(await reader.settle().isEmpty)
        try await f.start(service, configuration.id)
        #expect(EventCollector.actions(await reader.take(1)) == ["start"])
    }

    @Test("a restart the engine cannot make says nothing more after the die")
    func failedRestart() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration(restartPolicy: .always)
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        f.failNextLaunch.withLock { $0 = true }
        f.lastRuntime?.exit(1)
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["create", "start", "die"])
        #expect(await reader.settle(.milliseconds(400)).isEmpty)
        #expect(try await service.list().first?.status == .stopped)
    }

    @Test("a container made and removed between two listings is still made and removed in the events")
    func rapidCreateDelete() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let before = try await service.list()
        var configurations: [ContainerConfiguration] = []
        for _ in 0..<3 {
            let configuration = f.configuration()
            configurations.append(configuration)
            try await f.create(service, configuration)
            try await service.delete(id: configuration.id, force: false)
        }
        let after = try await service.list()
        // Two listings that a reader comparing them would find the same.
        #expect(before.isEmpty && after.isEmpty)
        let events = await reader.take(6)
        #expect(EventCollector.actions(events) == ["create", "destroy", "create", "destroy", "create", "destroy"])
        #expect(events.map(\.id) == configurations.flatMap { [$0.id, $0.id] })
    }

    @Test("a container made again under the same ID is another incarnation, after the first one's destroy")
    func recreateKeepsIdentity() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let configuration = f.configuration()
        let first = try await f.create(service, configuration)
        try await service.delete(id: configuration.id, force: false)
        let second = try await f.create(service, configuration)
        let events = await reader.take(3)
        #expect(EventCollector.actions(events) == ["create", "destroy", "create"])
        #expect(events.map(\.incarnation) == [first, first, second])
        #expect(first != second)
    }

    @Test("the route: a subscriber that reconnects with its cursor gets what it missed, and one too far behind is told of a gap")
    func routeReplayAndGap() async throws {
        let f = EventServiceFixture(limits: .init(replayed: 4))
        defer { f.cleanup() }
        let service = try f.service()
        let log = Logger(label: "ContainerEventServiceTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: [XPCRoute.containerEvent.rawValue: XPCServer.route(harness.events)], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "container-events-test")
        defer { xpc.close() }
        let client = ContainerClient(xpcClient: xpc)

        let first = try await client.events()
        #expect(first.processNonce == f.hub.processNonce)
        #expect(!first.gap)
        let reader = EventCollector(first.events)
        let a = f.configuration()
        try await f.create(service, a)
        let seen = await reader.take(1)
        #expect(EventCollector.actions(seen) == ["create"])
        let cursor = ContainerEventCursor(processNonce: first.processNonce, sequence: seen[0].sequence)

        // Gone for a while, during which the container is started and removed.
        try await f.start(service, a.id)
        try await service.delete(id: a.id, force: true)
        let resumed = try await client.events(since: cursor)
        #expect(!resumed.gap)
        let replay = EventCollector(resumed.events)
        let missed = await replay.take(4)
        #expect(EventCollector.actions(missed) == ["start", "kill", "die", "destroy"])
        #expect(missed.first?.sequence == cursor.sequence + 1)

        // Further behind than is kept: a gap, and the cursor to resume from.
        try await f.create(service, f.configuration())
        let stale = try await client.events(since: cursor)
        #expect(stale.gap)
        #expect(stale.cursor == f.hub.sequence)
        // Another process's cursor is a gap too.
        let foreign = try await client.events(since: ContainerEventCursor(processNonce: "another", sequence: 1))
        #expect(foreign.gap)
    }

    @Test("the health check says the server has the events route")
    func capabilityAdvertised() async throws {
        let log = Logger(label: "ContainerEventServiceTests")
        var routes: [XPCRoute: XPCServer.RouteHandler] = [:]
        var start = APIServer.Start()
        start.lifecycleGenerationOption = nil
        start.initializeHealthCheckService(processNonce: "nonce", log: log, routes: &routes)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) }), log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let client = XPCClient(endpoint: xpc_endpoint_create(listener), label: "capability-test")
        defer { client.close() }
        let reply = try await client.send(XPCMessage(route: XPCRoute.ping.rawValue), responseTimeout: .seconds(5))
        let capabilities = APIServerCapability.decode(reply.string(key: XPCKeys.apiServerCapabilities.rawValue))
        #expect(capabilities.contains(APIServerCapability.containerEvents.rawValue))
        // The control: an older server says nothing, which reads as no capabilities.
        #expect(APIServerCapability.decode(nil).isEmpty)
    }
}
