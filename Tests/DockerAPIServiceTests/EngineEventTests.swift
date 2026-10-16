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
import Logging
import Synchronization
import Testing

@testable import DockerAPIService

/// `/events` from the engine's events route (#230): what an engine event looks like to a Docker
/// client, following the engine and resuming where it left off, listing again after a gap, the
/// fallback to reading the engine once a second, and no event said twice.
@Suite(.timeLimit(.minutes(1)))
struct EngineEventTests {
    typealias Collector = EventTests.Collector

    /// An engine's events route, driven by the test: each subscription is a stream the test
    /// feeds and ends.
    final class Feed: DockerEngineEventFeed, Sendable {
        private struct State {
            var available: [Bool?] = [true]
            var nonce = "engine-1"
            var cursor: UInt64 = 0
            var gaps: [Bool] = []
            var current: AsyncThrowingStream<ContainerEvent, any Error>.Continuation?
            var since: [ContainerEventCursor?] = []
        }

        private let state = Mutex(State())

        /// What `available` answers, in turn; the last one repeats.
        func answer(_ values: Bool?...) {
            state.withLock { $0.available = values }
        }

        /// The engine was replaced: another process, numbering from `cursor`.
        func replace(nonce: String, cursor: UInt64 = 0) {
            state.withLock {
                $0.nonce = nonce
                $0.cursor = cursor
            }
        }

        /// The next subscriptions say a gap, in turn.
        func gap(_ values: Bool...) {
            state.withLock { $0.gaps = values }
        }

        func available() async -> Bool? {
            state.withLock { state in
                state.available.count > 1 ? state.available.removeFirst() : state.available.first ?? nil
            }
        }

        func subscribe(since: ContainerEventCursor?) async throws -> DockerEngineEvents {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: ContainerEvent.self, throwing: (any Error).self)
            return state.withLock { state in
                state.since.append(since)
                state.current?.finish()
                state.current = continuation
                let gap = state.gaps.isEmpty ? (since.map { $0.processNonce != state.nonce } ?? false) : state.gaps.removeFirst()
                return DockerEngineEvents(processNonce: state.nonce, cursor: state.cursor, gap: gap, events: stream)
            }
        }

        var subscriptions: [ContainerEventCursor?] { state.withLock { $0.since } }

        /// An event from the engine, numbered after the last.
        @discardableResult
        func send(
            _ action: ContainerEvent.Action, id: String = "abc123def456", labels: [String: String] = EngineEventTests.labels, exitCode: Int32? = nil,
            health: HealthStatus? = nil, attributes: [String: String] = [:], incarnation: String = "inc-1"
        ) -> ContainerEvent {
            state.withLock { state in
                state.cursor += 1
                let event = ContainerEvent(
                    sequence: state.cursor, timeNano: Int64(Date().timeIntervalSince1970 * 1_000_000_000), id: id, incarnation: incarnation,
                    action: action, name: labels[DockerLabels.name] ?? id, image: "docker.io/library/nginx:latest", labels: labels,
                    exitCode: exitCode, health: health, attributes: attributes)
                state.current?.yield(event)
                return event
            }
        }

        /// The stream ends, as when the engine goes or closes a subscriber that fell behind.
        func end() {
            state.withLock { $0.current?.finish() }
        }
    }

    static let dockerID = Fixtures.id("abc123def456")
    static let labels: [String: String] = [
        DockerLabels.id: dockerID, DockerLabels.name: "web", DockerLabels.image: "nginx", "com.docker.compose.project": "demo",
        "com.docker.compose.service": "web", "com.docker.compose.oneoff": "False",
    ]

    static func waitFor(_ condition: @Sendable () async -> Bool, within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    static func followingBus(
        _ feed: Feed, engine: EventTests.Engine = EventTests.Engine(), limits: DockerEventLimits = .init(engineRecheck: .milliseconds(50))
    ) async throws -> (DockerEventBus, Collector) {
        let bus = DockerEventBus(limits: limits, source: engine.source, feed: feed)
        let collector = try await EventTests.subscribe(bus)
        #expect(await waitFor { await bus.followingEngine })
        return (bus, collector)
    }

    // MARK: The shape

    @Test("an engine event is a container event with its labels, name, image and exit code in Actor.Attributes, as dockerd's")
    func shape() throws {
        let event = ContainerEvent(
            sequence: 4, timeNano: 1_700_000_000_123_456_789, id: "abc123def456", incarnation: "inc-1", action: .die, name: "web",
            image: "docker.io/library/nginx:latest", labels: Self.labels, exitCode: 143)
        let docker = try #require(DockerEventBus.dockerEvent(event))
        #expect(docker.type == "container")
        #expect(docker.action == "die")
        #expect(docker.actorID == Self.dockerID)
        #expect(docker.attributes["name"] == "web")
        #expect(docker.attributes["image"] == "nginx")
        #expect(docker.attributes["exitCode"] == "143")
        #expect(docker.attributes["com.docker.compose.service"] == "web")
        // This service's own labels are not shown, as no view of a container shows them.
        #expect(docker.attributes.keys.allSatisfy { !$0.hasPrefix(DockerLabels.prefix) })
        // To the microsecond: a Date holds no finer.
        #expect(abs(docker.message.timeNano - 1_700_000_000_123_456_789) < 1_000)
        #expect(docker.message.status == "die")
        #expect(docker.message.from == "nginx")

        // The rest of the actions, as dockerd names and fills them.
        var kill = event
        kill.action = .kill
        kill.attributes = ["signal": "SIGTERM"]
        #expect(DockerEventBus.dockerEvent(kill)?.attributes["signal"] == "15")
        #expect(DockerEventBus.dockerEvent(kill)?.attributes["exitCode"] == nil)
        var health = event
        health.action = .healthStatus
        health.health = .healthy
        #expect(DockerEventBus.dockerEvent(health)?.action == "health_status: healthy")
        health.health = nil
        #expect(DockerEventBus.dockerEvent(health) == nil)
        var rename = event
        rename.action = .rename
        rename.attributes = ["oldName": "old"]
        #expect(DockerEventBus.dockerEvent(rename)?.attributes["oldName"] == "/old")

        // A container this service did not make: hashed ID, its engine ID as name, the image short.
        let foreign = ContainerEvent(
            sequence: 5, timeNano: 1, id: "my-app", incarnation: "i", action: .start, name: "my-app", image: "docker.io/library/alpine:3",
            labels: ["role": "x"])
        let shown = try #require(DockerEventBus.dockerEvent(foreign))
        #expect(shown.actorID == DockerIdentityTable.foreignID(engineID: "my-app"))
        #expect(shown.attributes == ["role": "x", "name": "my-app", "image": "alpine:3"])
        // Control: a Docker ID label that is not this container's is not believed.
        var forged = foreign
        forged.labels[DockerLabels.id] = Self.dockerID
        #expect(DockerEventBus.dockerEvent(forged)?.actorID == DockerIdentityTable.foreignID(engineID: "my-app"))
    }

    @Test("compose's filters take the events of its project's containers, and only those")
    func composeFilters() throws {
        let filter = try DockerEventFilter([
            "label": ["com.docker.compose.project=demo", "com.docker.compose.oneoff=False"], "type": ["container"],
        ])
        let event = ContainerEvent(
            sequence: 1, timeNano: 1, id: "abc123def456", incarnation: "i", action: .start, name: "web", image: "nginx", labels: Self.labels)
        #expect(filter.includes(try #require(DockerEventBus.dockerEvent(event))))
        var other = event
        other.labels["com.docker.compose.project"] = "another"
        #expect(!filter.includes(try #require(DockerEventBus.dockerEvent(other))))
        var oneoff = event
        oneoff.labels["com.docker.compose.oneoff"] = "True"
        #expect(!filter.includes(try #require(DockerEventBus.dockerEvent(oneoff))))
    }

    // MARK: Following the engine

    @Test("the engine's create, start, die and destroy reach a client within a second, in order, once")
    func follows() async throws {
        let feed = Feed()
        let (bus, collector) = try await Self.followingBus(feed)
        let clock = ContinuousClock()
        let began = clock.now
        feed.send(.create)
        feed.send(.start)
        feed.send(.die, exitCode: 0)
        feed.send(.destroy)
        let events = await collector.take(4)
        #expect(clock.now - began < .seconds(1))
        #expect(events.map(\.action) == ["create", "start", "die", "destroy"])
        #expect(events.allSatisfy { $0.actorID == Self.dockerID && $0.attributes["name"] == "web" })
        #expect(events[2].attributes["exitCode"] == "0")
        #expect(await collector.settle().isEmpty)
        await bus.shutdown()
    }

    @Test("what this service does to a container is the engine's to say while it follows the engine, but restart and other types are still its own")
    func noDuplicates() async throws {
        let feed = Feed()
        let (bus, collector) = try await Self.followingBus(feed)
        let container = DockerContainer(snapshot: Fixtures.dockerContainer(name: "web", dockerID: Self.dockerID), dockerID: Self.dockerID, name: "web")
        for (action, change) in [
            ("create", DockerEventBus.ContainerChange.created), ("start", .started), ("kill", .none), ("die", .died(exitCode: 143)),
            ("stop", .none), ("rename", .none), ("destroy", .removed),
        ] {
            await bus.container(action, container, change: change)
        }
        await bus.container("restart", container, change: .none)
        await bus.publish(type: "network", action: "connect", actorID: "net", attributes: [:])
        #expect(await collector.take(2).map(\.action) == ["restart", "connect"])
        // The engine's own are said.
        feed.send(.kill, attributes: ["signal": "SIGTERM"])
        #expect(await collector.take(1).map(\.action) == ["kill"])
        #expect(await collector.settle().isEmpty)
        await bus.shutdown()
    }

    @Test("a stream that ends is followed again from the last event read, without listing")
    func resumes() async throws {
        let feed = Feed()
        let engine = EventTests.Engine()
        let (bus, collector) = try await Self.followingBus(feed, engine: engine)
        let reads = engine.reads.withLock { $0 }
        feed.send(.create)
        let last = feed.send(.start)
        _ = await collector.take(2)
        feed.end()
        #expect(await Self.waitFor { feed.subscriptions.count == 2 })
        #expect(feed.subscriptions.last == ContainerEventCursor(processNonce: "engine-1", sequence: last.sequence))
        #expect(engine.reads.withLock { $0 } == reads)
        feed.send(.die, exitCode: 1)
        #expect(await collector.take(1).map(\.action) == ["die"])
        await bus.shutdown()
    }

    @Test("after a gap, and after the engine is replaced, the containers are listed again and what changed meanwhile is said")
    func resyncs() async throws {
        for replaced in [false, true] {
            let feed = Feed()
            let engine = EventTests.Engine()
            let web = EventTests.container("web", .running, started: Fixtures.now)
            engine.set([web])
            let (bus, collector) = try await Self.followingBus(feed, engine: engine)
            // Missed while the stream was down: web died, db appeared.
            engine.set([EventTests.container("web", .stopped, started: Fixtures.now, exitCode: 2), EventTests.container("db")])
            if replaced {
                feed.replace(nonce: "engine-2")
            } else {
                feed.gap(true)
            }
            feed.end()
            let events = await collector.take(2)
            #expect(EventTests.actions(events).sorted() == ["create db", "die web"])
            #expect(feed.subscriptions.count == 2)
            await bus.shutdown()
        }
    }

    @Test("an engine without the events route is read once a second, with this service's own reports; one that gains it is followed")
    func fallback() async throws {
        let feed = Feed()
        feed.answer(false)
        let engine = EventTests.Engine()
        let bus = DockerEventBus(
            limits: .init(pollInterval: .milliseconds(10), engineRecheck: .milliseconds(30)), source: engine.source, feed: feed)
        let collector = try await EventTests.subscribe(bus)
        #expect(await Self.waitFor { engine.reads.withLock { $0 } >= 2 })
        #expect(!(await bus.followingEngine))
        // Read from the engine's containers, as stage A did.
        engine.set([EventTests.container("web")])
        #expect(EventTests.actions(await collector.take(1)) == ["create web"])
        // And this service's own reports are said while nothing else says them.
        await bus.container("kill", EventTests.container("web"), change: .none)
        #expect(await collector.take(1).map(\.action) == ["kill"])
        #expect(!(await bus.followingEngine))
        // The engine gained the route: followed from then on.
        feed.answer(true)
        #expect(await Self.waitFor { await bus.followingEngine })
        feed.send(.start)
        let followed = await collector.take(1)
        #expect(followed.map(\.action) == ["start"], "\(followed.map { "\($0.action) \($0.attributes["name"] ?? "")" })")
        await bus.shutdown()
    }

    @Test("an engine that does not answer is read as one without the route, and is asked again")
    func engineDown() async throws {
        let feed = Feed()
        feed.answer(nil, nil, true)
        let (bus, _) = try await Self.followingBus(feed)
        #expect(feed.subscriptions.count == 1)
        await bus.shutdown()
    }

    @Test("a container this service removes and makes again under the same ID is not destroyed and created to a client")
    func recreateIsQuiet() async throws {
        let feed = Feed()
        let (bus, collector) = try await Self.followingBus(feed)
        let container = DockerContainer(snapshot: Fixtures.dockerContainer(name: "web", dockerID: Self.dockerID), dockerID: Self.dockerID, name: "web")
        await bus.recreating(container)
        feed.send(.destroy, incarnation: "inc-1")
        feed.send(.create, incarnation: "inc-2")
        feed.send(.start, incarnation: "inc-2")
        #expect(await collector.take(1).map(\.action) == ["start"])
        // Control: once made again, a destroy is a destroy.
        feed.send(.destroy, incarnation: "inc-2")
        #expect(await collector.take(1).map(\.action) == ["destroy"])
        await bus.shutdown()
    }

    @Test("no one subscribed: the engine is not followed")
    func idle() async throws {
        let feed = Feed()
        let bus = DockerEventBus(source: EventTests.Engine().source, feed: feed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(feed.subscriptions.isEmpty)
        let (id, stream) = try await bus.subscribe(try DockerEventFilter())
        #expect(await Self.waitFor { feed.subscriptions.count == 1 })
        await bus.cancel(id)
        _ = stream
        #expect(!(await bus.followingEngine))
    }

    @Test("the engine's own containers are not reported, and a resync does not report them destroyed; a container of a client's is")
    func infrastructureHidden() async throws {
        let feed = Feed()
        let engine = EventTests.Engine()
        let (bus, collector) = try await Self.followingBus(feed, engine: engine)
        feed.send(.create, id: "buildkit", labels: [ResourceLabelKeys.plugin: "container-build"])
        feed.send(.start, id: "buildkit", labels: [ResourceLabelKeys.plugin: "container-build"])
        // The control, on the same path.
        feed.send(.create, id: "abc123def456")
        #expect(await collector.take(1).map(\.actorID) == [Self.dockerID])
        // A gap: the listing, which leaves the builder out, is compared with what was seen.
        engine.set([EventTests.container("abc1")])
        feed.gap(true)
        feed.end()
        let resynced = await collector.take(1)
        #expect(resynced.allSatisfy { $0.attributes["name"] != "buildkit" && $0.actorID != DockerIdentityTable.foreignID(engineID: "buildkit") })
        #expect(await collector.settle().allSatisfy { $0.actorID != DockerIdentityTable.foreignID(engineID: "buildkit") })
        await bus.shutdown()
    }
}
