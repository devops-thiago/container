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
import NIOCore
import NIOHTTP1
import Synchronization
import Testing

@testable import DockerAPIService

/// `GET /events`: the bus, what reading the engine finds, what this service reports itself,
/// dockerd's filter, and the stream.
@Suite(.timeLimit(.minutes(1)))
struct EventTests {
    typealias Harness = DockerAPIServerTests.Harness

    /// Containers the test changes between readings.
    final class Engine: Sendable {
        let containers = Mutex<[DockerContainer]>([])
        let reads = Mutex(0)

        var source: DockerEventBus.ContainerSource {
            { [self] in
                reads.withLock { $0 += 1 }
                return containers.withLock { $0 }
            }
        }

        func set(_ list: [DockerContainer]) {
            containers.withLock { $0 = list }
        }
    }

    static func container(
        _ name: String, _ status: RuntimeStatus = .stopped, started: Date? = nil, exitCode: Int32? = nil, health: HealthStatus? = nil,
        labels: [String: String] = [:]
    ) -> DockerContainer {
        let dockerID = Fixtures.id(name.padding(toLength: 4, withPad: "0", startingAt: 0).map { $0.isHexDigit ? String($0) : "a" }.joined())
        var snapshot = Fixtures.snapshot(
            Fixtures.configuration(id: String(dockerID.prefix(12)), labels: labels), status: status, started: started, exitCode: exitCode,
            exited: exitCode == nil ? nil : Fixtures.now)
        snapshot.health = health.map { ContainerHealth(status: $0) }
        return DockerContainer(snapshot: snapshot, dockerID: dockerID, name: name)
    }

    /// Reads a subscription for the whole test, so that the test can look at what arrived
    /// without ending it: a cancelled read of an `AsyncStream` ends the stream.
    final class Collector: Sendable {
        final class Received: Sendable {
            let events = Mutex<[DockerEvent]>([])
            let finished = Mutex(false)
        }

        private let received = Received()
        private let taken = Mutex(0)
        private let task: Task<Void, Never>

        init(_ stream: AsyncStream<DockerEvent>) {
            let received = self.received
            task = Task {
                for await event in stream { received.events.withLock { $0.append(event) } }
                received.finished.withLock { $0 = true }
            }
        }

        deinit { task.cancel() }

        var isFinished: Bool { received.finished.withLock { $0 } }

        /// The next `count` events, or what arrived of them within a second.
        func take(_ count: Int) async -> [DockerEvent] {
            for _ in 0..<200 where received.events.withLock({ $0.count }) - taken.withLock({ $0 }) < count {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return next()
        }

        /// What arrives within a short while.
        func settle(_ within: Duration = .milliseconds(100)) async -> [DockerEvent] {
            try? await Task.sleep(for: within)
            return next()
        }

        private func next() -> [DockerEvent] {
            let all = received.events.withLock { $0 }
            return taken.withLock { taken in
                defer { taken = all.count }
                return Array(all[taken...])
            }
        }
    }

    static func subscribe(_ bus: DockerEventBus, _ filter: DockerEventFilter = try! DockerEventFilter()) async throws -> Collector {
        Collector(try await bus.subscribe(filter).events)
    }

    static func actions(_ events: [DockerEvent]) -> [String] {
        events.map { "\($0.action) \($0.attributes["name"] ?? $0.actorID)" }
    }

    // MARK: Reading the engine

    @Test("reading the engine reports what appeared, started, died, changed health and went; the first reading reports nothing")
    func pollDiff() async throws {
        let engine = Engine()
        let bus = DockerEventBus()
        let stream = try await Self.subscribe(bus)
        let started = Fixtures.now

        engine.set([Self.container("web")])
        await bus.poll(engine.source)
        engine.set([Self.container("web", .running, started: started), Self.container("db")])
        await bus.poll(engine.source)
        engine.set([
            Self.container("web", .stopped, started: started, exitCode: 3),
            Self.container("db", .running, started: started, health: .healthy),
        ])
        await bus.poll(engine.source)
        engine.set([Self.container("db", .running, started: started, health: .healthy)])
        await bus.poll(engine.source)
        engine.set([])
        await bus.poll(engine.source)

        let events = await stream.take(8)
        #expect(
            Self.actions(events) == [
                "start web", "create db", "die web", "start db", "health_status: healthy db", "destroy web", "die db", "destroy db",
            ])
        #expect(events[2].attributes["exitCode"] == "3")
        #expect(events.allSatisfy { $0.type == "container" })
        #expect(events[0].actorID == Self.container("web").dockerID)
        #expect(events[0].attributes["image"] == "alpine:latest")
    }

    @Test("a restart between two readings is a die and a start")
    func pollRestart() async throws {
        let engine = Engine()
        let bus = DockerEventBus()
        let stream = try await Self.subscribe(bus)
        engine.set([Self.container("web", .running, started: Fixtures.now)])
        await bus.poll(engine.source)
        engine.set([Self.container("web", .running, started: Fixtures.now.addingTimeInterval(5))])
        await bus.poll(engine.source)
        #expect(Self.actions(await stream.take(2)) == ["die web", "start web"])
        // Control: the same start time twice is no change.
        await bus.poll(engine.source)
        #expect(await stream.settle().isEmpty)
    }

    @Test("what this service reported itself is not reported again by the reading after it")
    func ownChangesNotRepeated() async throws {
        let engine = Engine()
        let bus = DockerEventBus()
        let stream = try await Self.subscribe(bus)
        let web = Self.container("web")
        engine.set([web])
        await bus.poll(engine.source)

        await bus.container("start", web, change: .started)
        engine.set([Self.container("web", .running, started: Fixtures.now)])
        await bus.poll(engine.source)
        await bus.container("die", web, change: .died(exitCode: 0))
        // The same exit, reported again by the process's waiter, is said once.
        await bus.container("die", web, change: .died(exitCode: 0))
        engine.set([Self.container("web", .stopped, started: Fixtures.now, exitCode: 0)])
        await bus.poll(engine.source)
        await bus.container("destroy", web, change: .removed)
        engine.set([])
        await bus.poll(engine.source)
        #expect(Self.actions(await stream.settle()) == ["start web", "die web", "destroy web"])

        // Control: a change this service did not report is found by the reading.
        engine.set([Self.container("api", .running, started: Fixtures.now)])
        await bus.poll(engine.source)
        #expect(Self.actions(await stream.settle()) == ["create api", "start api"])
    }

    @Test("a reading taken before this service's change does not undo it")
    func staleReadingIgnored() async throws {
        let bus = DockerEventBus()
        let stream = try await Self.subscribe(bus)
        let web = Self.container("web")
        await bus.poll({ [web] })

        // The reading is taken, then the start is reported, then the reading lands.
        await bus.poll({
            await bus.container("start", web, change: .started)
            return [web]
        })
        // A reading taken after the start sees it running, which is no news.
        await bus.poll({ [Self.container("web", .running, started: Fixtures.now)] })
        #expect(Self.actions(await stream.settle()) == ["start web"])

        // Control: the same stale reading, with no change of this service's in between, is a die.
        await bus.poll({ [web] })
        #expect(Self.actions(await stream.settle()) == ["die web"])
    }

    @Test("the engine is read only while someone is subscribed")
    func pollsOnlyWhileSubscribed() async throws {
        let engine = Engine()
        let bus = DockerEventBus(limits: .init(pollInterval: .milliseconds(10)), source: engine.source)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reads.withLock { $0 } == 0)

        // Held: a stream nobody holds is a subscription that ends.
        let (id, held) = try await bus.subscribe(DockerEventFilter())
        defer { withExtendedLifetime(held) {} }
        for _ in 0..<200 where engine.reads.withLock({ $0 }) < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(engine.reads.withLock { $0 } >= 3)

        await bus.cancel(id)
        try await Task.sleep(for: .milliseconds(30))
        let after = engine.reads.withLock { $0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.reads.withLock { $0 } == after)
        #expect(await bus.subscriberCount == 0)
    }

    // MARK: Bounds

    @Test("a subscriber that falls behind is dropped with a warning, and one its filter spares is not")
    func slowSubscriberDropped() async throws {
        let captured = CapturedLog()
        let bus = DockerEventBus(limits: .init(bufferedEvents: 2), log: captured.logger)
        let (_, slow) = try await bus.subscribe(DockerEventFilter())
        let spared = Collector(try await bus.subscribe(try DockerEventFilter(["type": ["network"]])).events)
        for index in 0..<3 {
            await bus.publish(type: "volume", action: "create", actorID: "v\(index)", attributes: [:])
        }
        #expect(await bus.subscriberCount == 1)
        // The slow one gets what its buffer held, then its stream ends.
        var held: [String] = []
        for await event in slow { held.append(event.actorID) }
        #expect(held == ["v0", "v1"])
        #expect(captured.text.contains("dropped an events client that fell behind"))

        // Control: the spared one is still subscribed and gets its events.
        await bus.publish(type: "network", action: "create", actorID: "n1", attributes: [:])
        #expect(await spared.take(1).map(\.actorID) == ["n1"])
    }

    @Test("subscribers are bounded")
    func subscriberLimit() async throws {
        let bus = DockerEventBus(limits: .init(maxSubscribers: 1))
        let (id, held) = try await bus.subscribe(DockerEventFilter())
        await #expect(throws: DockerAPIError.self) { _ = try await bus.subscribe(DockerEventFilter()) }
        withExtendedLifetime(held) {}
        // Control: once one leaves, another may come.
        await bus.cancel(id)
        let next = try await bus.subscribe(DockerEventFilter())
        withExtendedLifetime(next) {}
    }

    @Test("with nobody subscribed, an event goes nowhere and nothing is kept")
    func noHistory() async throws {
        let bus = DockerEventBus()
        await bus.publish(type: "volume", action: "create", actorID: "early", attributes: [:])
        let stream = try await Self.subscribe(bus)
        await bus.publish(type: "volume", action: "create", actorID: "late", attributes: [:])
        #expect(await stream.take(1).map(\.actorID) == ["late"])
    }

    // MARK: Filters

    static func event(_ type: String, _ action: String, _ id: String, _ attributes: [String: String] = [:]) -> DockerEvent {
        DockerEvent(type: type, action: action, actorID: id, attributes: attributes, time: Fixtures.now)
    }

    @Test("filters match as dockerd's do")
    func filters() throws {
        let web = Self.event("container", "start", Fixtures.id("abc1"), ["name": "web", "image": "alpine:3.22", "tier": "front"])
        let health = Self.event("container", "health_status: healthy", Fixtures.id("abc1"), ["name": "web", "image": "alpine:3.22"])
        let pull = Self.event("image", "pull", "alpine:3.22", ["name": "alpine"])
        let volume = Self.event("volume", "create", "data", ["driver": "local"])

        func takes(_ filters: [String: [String]], _ event: DockerEvent) throws -> Bool {
            try DockerEventFilter(filters).includes(event)
        }
        #expect(try takes([:], web))
        #expect(try takes(["type": ["container"]], web))
        #expect(try !takes(["type": ["image"]], web))
        #expect(try takes(["event": ["start"]], web))
        #expect(try !takes(["event": ["stop"]], web))
        // health_status matches its longer actions; another action only whole.
        #expect(try takes(["event": ["health_status"]], health))
        #expect(try !takes(["event": ["health"]], health))
        // A container by name or ID, by prefix.
        #expect(try takes(["container": ["web"]], web))
        #expect(try takes(["container": ["abc1"]], web))
        #expect(try !takes(["container": ["db"]], web))
        // A container filter holds back other types, as in dockerd.
        #expect(try !takes(["container": ["web"]], volume))
        // An image by reference, with or without its tag; a container by the image it runs.
        #expect(try takes(["image": ["alpine"]], pull))
        #expect(try takes(["image": ["alpine:3.22"]], pull))
        #expect(try takes(["image": ["alpine"]], web))
        #expect(try !takes(["image": ["redis"]], web))
        #expect(try takes(["label": ["tier=front"]], web))
        #expect(try takes(["label": ["tier"]], web))
        #expect(try !takes(["label": ["tier=back"]], web))
        #expect(try takes(["volume": ["data"]], volume))
        #expect(try !takes(["volume": ["logs"]], volume))
        #expect(try takes(["scope": ["local"]], web))
        #expect(try !takes(["scope": ["swarm"]], web))
    }

    @Test("an unknown filter is refused in dockerd's words")
    func unknownFilter() {
        #expect(throws: DockerAPIError.badRequest("invalid filter 'action'")) { try DockerEventFilter(["action": ["start"]]) }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'colour'")) { try DockerEventFilter(["colour": ["red"]]) }
    }

    @Test("a tag is stripped from a reference, not a registry's port")
    func stripTag() {
        #expect(DockerEventFilter.stripTag("alpine:3.22") == "alpine")
        #expect(DockerEventFilter.stripTag("localhost:5000/app:1") == "localhost:5000/app")
        #expect(DockerEventFilter.stripTag("localhost:5000/app") == "localhost:5000/app")
        #expect(DockerEventFilter.stripTag("app@sha256:abc") == "app")
    }

    // MARK: The stream

    @Test("an event is one JSON line in dockerd's shape, with the fields 1.48 still sends")
    func wireShape() throws {
        let event = DockerEvent(
            type: "container", action: "die", actorID: Fixtures.id("abc1"), attributes: ["name": "web", "image": "alpine", "exitCode": "3"],
            time: Date(timeIntervalSince1970: 1_700_000_000.5))
        let object = try #require(try JSONSerialization.jsonObject(with: DockerJSON.encoder.encode(event.message)) as? [String: Any])
        #expect(object["Type"] as? String == "container")
        #expect(object["Action"] as? String == "die")
        #expect(object["status"] as? String == "die")
        #expect(object["id"] as? String == Fixtures.id("abc1"))
        #expect(object["from"] as? String == "alpine")
        #expect(object["scope"] as? String == "local")
        #expect(object["time"] as? Int == 1_700_000_000)
        #expect(object["timeNano"] as? Int == 1_700_000_000_500_000_000)
        let actor = try #require(object["Actor"] as? [String: Any])
        #expect(actor["ID"] as? String == Fixtures.id("abc1"))
        #expect((actor["Attributes"] as? [String: String])?["exitCode"] == "3")

        // Control: a volume event has none of the legacy fields.
        let volume = try #require(
            try JSONSerialization.jsonObject(with: DockerJSON.encoder.encode(Self.event("volume", "create", "data").message)) as? [String: Any])
        #expect(volume["status"] == nil)
        #expect(volume["from"] == nil)
    }

    @Test("the stream sends what happens, filtered, and ends when the client goes")
    func streams() async throws {
        let bus = DockerEventBus()
        let harness = try await Harness.start { EventRoutes.register(on: &$0, events: bus) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            // {"type":["volume"]}
            try await client.send("GET /v1.48/events?filters=%7B%22type%22%3A%5B%22volume%22%5D%7D HTTP/1.1\r\nHost: d\r\n\r\n")
            let head = try await client.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 200"))
            #expect(head.contains("application/json"))
            #expect(await bus.subscriberCount == 1)
            await bus.publish(type: "network", action: "create", actorID: "skipped", attributes: [:])
            await bus.publish(type: "volume", action: "create", actorID: "data", attributes: ["driver": "local"])
            let line = try await client.read(through: "}\n")
            #expect(line.contains(#""Type":"volume""#))
            #expect(line.contains(#""ID":"data""#))
            #expect(!line.contains("skipped"))
        }
        // The client went: its subscription goes with it.
        for _ in 0..<200 where await bus.subscriberCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await bus.subscriberCount == 0)
    }

    @Test("an until already past answers at once with nothing; a later one ends the stream then")
    func until() async throws {
        let bus = DockerEventBus()
        let harness = try await Harness.start { EventRoutes.register(on: &$0, events: bus) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("GET /v1.48/events?until=1000 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            let answer = try await client.readToEnd()
            #expect(answer.hasPrefix("HTTP/1.1 200"))
            #expect(answer.hasSuffix("0\r\n\r\n"))
        }
        let soon = Date().timeIntervalSince1970 + 0.3
        try await harness.withClient { client in
            try await client.send("GET /v1.48/events?until=\(String(format: "%.3f", soon)) HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            await bus.publish(type: "volume", action: "create", actorID: "in-time", attributes: [:])
            // Ends on its own, at until.
            let rest = try await client.readToEnd()
            #expect(rest.contains("in-time"))
            #expect(rest.hasSuffix("0\r\n\r\n"))
        }
        #expect(await bus.subscriberCount == 0)
    }

    @Test("since and until are refused as dockerd refuses them")
    func badTimes() async throws {
        var router = DockerRouter()
        EventRoutes.register(on: &router, events: DockerEventBus())
        func status(_ query: String) async throws -> (HTTPResponseStatus, String) {
            guard case .data(let status, _, let body, _) = await router.respond(to: try DockerRequest(method: .GET, uri: "/events?\(query)", headers: [:], body: ByteBuffer()))
            else { return (.ok, "stream") }
            return (status, String(buffer: body))
        }
        #expect(try await status("since=abc") == (.badRequest, #"{"message":"invalid value for 'since': strconv.ParseInt: parsing \"abc\": invalid syntax"}"#))
        #expect(try await status("since=2000&until=1000") == (.badRequest, #"{"message":"`since` time (2000) cannot be after `until` time (1000)"}"#))
        #expect(try await status("filters=%7B%22action%22%3A%5B%22start%22%5D%7D").0 == .badRequest)
        // Control: good times stream.
        #expect(try await status("since=1000.5").1 == "stream")
    }

    @Test("since drops live events from before it")
    func since() async throws {
        let bus = DockerEventBus()
        let harness = try await Harness.start { EventRoutes.register(on: &$0, events: bus) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            let later = Int(Date().timeIntervalSince1970) + 3600
            try await client.send("GET /v1.48/events?since=\(later) HTTP/1.1\r\nHost: d\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            await bus.publish(type: "volume", action: "create", actorID: "too-early", attributes: [:])
            await bus.publish(DockerEvent(type: "volume", action: "create", actorID: "late-enough", attributes: [:], time: Date(timeIntervalSince1970: Double(later + 1))))
            let line = try await client.read(through: "}\n")
            #expect(line.contains("late-enough"))
            #expect(!line.contains("too-early"))
        }
    }

    // MARK: What the routes report

    @Test("the container routes report create, start, kill, die, stop, rename and destroy, in dockerd's order")
    func containerRoutes() async throws {
        let engine = FakeEngine()
        let bus = DockerEventBus()
        let identities = DockerIdentityStore(persistence: nil)
        var router = DockerRouter()
        ContainerRoutes.register(
            on: &router, engine: engine, identities: identities, streams: DockerContainerStreams(engine: engine, events: bus), now: { Fixtures.now },
            events: bus)
        let stream = try await Self.subscribe(bus)
        func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws -> HTTPResponseStatus {
            guard case .data(let status, _, _, _) = await router.respond(to: try DockerRequest(method: method, uri: uri, headers: [:], body: ByteBuffer(string: body)))
            else { return .internalServerError }
            return status
        }
        #expect(try await call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine","Labels":{"tier":"front"}}"#) == .created)
        #expect(try await call(.POST, "/containers/web/start") == .noContent)
        #expect(try await call(.POST, "/containers/web/stop") == .noContent)
        #expect(try await call(.POST, "/containers/web/rename?name=api") == .noContent)
        #expect(try await call(.DELETE, "/containers/api") == .noContent)

        let events = await stream.take(7)
        #expect(events.map(\.action) == ["create", "start", "kill", "die", "stop", "rename", "destroy"])
        #expect(events[0].attributes["tier"] == "front")
        #expect(events[0].attributes["image"] == "alpine")
        #expect(events[0].attributes["name"] == "web")
        #expect(events[2].attributes["signal"] == "15")
        #expect(events[3].attributes["exitCode"] == "0")
        #expect(events[5].attributes["oldName"] == "/web")
        #expect(events[5].attributes["name"] == "api")
        #expect(Set(events.map(\.actorID)).count == 1)
        // Nothing more: the process's own exit was not reported twice.
        #expect(await stream.settle().isEmpty)
    }

    @Test("a forced removal of a running container reports kill, die and destroy, and its process's late exit is not reported after")
    func forcedRemoval() async throws {
        let engine = FakeEngine()
        let bus = DockerEventBus()
        let identities = DockerIdentityStore(persistence: nil)
        var router = DockerRouter()
        ContainerRoutes.register(
            on: &router, engine: engine, identities: identities, streams: DockerContainerStreams(engine: engine, events: bus), now: { Fixtures.now },
            events: bus)
        let stream = try await Self.subscribe(bus)
        func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws {
            _ = await router.respond(to: try DockerRequest(method: method, uri: uri, headers: [:], body: ByteBuffer(string: body)))
        }
        try await call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine"}"#)
        // Started without an attach: the process and its waiter are the service's.
        try await call(.POST, "/containers/web/start")
        try await call(.DELETE, "/containers/web?force=1")
        #expect(await stream.take(5).map(\.action) == ["create", "start", "kill", "die", "destroy"])
        // The waiter hears the exit the removal caused; it is not news after the destroy.
        #expect(await stream.settle(.milliseconds(300)).isEmpty)

        // The waiter can be later than the destroy: its exit is still not reported then.
        let api = Self.container("api", .running, started: Fixtures.now)
        await bus.container("die", api, change: .died(exitCode: 137))
        await bus.container("destroy", api, change: .removed)
        await bus.container("die", api, change: .died(exitCode: 137))
        #expect(Self.actions(await stream.settle()) == ["die api", "destroy api"])

        // Control: an exit for a container not destroyed is reported.
        let other = Self.container("db", .running, started: Fixtures.now)
        await bus.container("die", other, change: .died(exitCode: 1))
        #expect(await stream.take(1).map(\.action) == ["die"])
    }

    @Test("the volume and network routes report what they make and remove")
    func volumeAndNetworkRoutes() async throws {
        let bus = DockerEventBus()
        let engine = FakeEngine()
        let identities = DockerIdentityStore(persistence: nil)
        let volumes = FakeVolumes()
        let networks = FakeNetworks()
        var router = DockerRouter()
        VolumeRoutes.register(on: &router, engine: volumes, containers: engine, identities: identities, events: bus)
        NetworkRoutes.register(on: &router, engine: networks, containers: engine, identities: identities, events: bus)
        let stream = try await Self.subscribe(bus)
        func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws {
            _ = await router.respond(to: try DockerRequest(method: method, uri: uri, headers: [:], body: ByteBuffer(string: body)))
        }
        try await call(.POST, "/volumes/create", body: #"{"Name":"data"}"#)
        try await call(.DELETE, "/volumes/data")
        try await call(.POST, "/networks/create", body: #"{"Name":"backend"}"#)
        try await call(.DELETE, "/networks/backend")
        let events = await stream.take(4)
        #expect(events.map { "\($0.type) \($0.action)" } == ["volume create", "volume destroy", "network create", "network destroy"])
        #expect(events[0].actorID == "data")
        #expect(events[0].attributes["driver"] == "local")
        #expect(events[2].attributes["name"] == "backend")
        #expect(events[2].attributes["type"] == "bridge")
    }

    @Test("the image routes report a pull, a tag and a delete")
    func imageRoutes() async throws {
        let bus = DockerEventBus()
        let routes = try ImageRoutesTests()
        var router = DockerRouter()
        ImageRoutes.register(
            on: &router, engine: routes.images, containers: routes.engine, identities: routes.identities, scratch: routes.scratch,
            progressInterval: .milliseconds(1), events: bus)
        let stream = try await Self.subscribe(bus)
        _ = await router.respond(to: try DockerRequest(method: .POST, uri: "/images/alpine:3.22/tag?repo=mine&tag=v1", headers: [:], body: ByteBuffer()))
        _ = await router.respond(to: try DockerRequest(method: .DELETE, uri: "/images/mine:v1", headers: [:], body: ByteBuffer()))
        let events = await stream.take(2)
        #expect(events.map(\.action) == ["tag", "untag"])
        #expect(events[0].attributes["name"] == "mine:v1")
        #expect(events.allSatisfy { $0.actorID == StoreFixtures.digest("a") })

        // A pull, over a socket, reported once it is done.
        let pulling = try await Harness.start { ImageRoutes.register(on: &$0, engine: routes.images, progressInterval: .milliseconds(1), events: bus) }
        defer { Task { try? await pulling.stop() } }
        try await pulling.withClient { client in
            try await client.send("POST /v1.48/images/create?fromImage=redis&tag=7 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.readToEnd()
        }
        let pulled = await stream.take(1)
        #expect(pulled.map(\.action) == ["pull"])
        #expect(pulled.first?.actorID == "redis:7")
        #expect(pulled.first?.attributes["name"] == "redis")
    }
}
