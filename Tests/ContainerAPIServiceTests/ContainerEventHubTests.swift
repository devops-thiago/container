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

import ContainerAPIClient
import ContainerResource
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

/// The event hub on its own: numbering, the pipe each subscriber reads, the bounds on a
/// subscriber that does not read, and what a subscriber that reconnects is given.
@Suite(.timeLimit(.minutes(1)))
struct ContainerEventHubTests {
    static let log = Logger(label: "ContainerEventHubTests")

    static func snapshot(_ id: String = "hub", labels: [String: String] = [:]) -> ContainerSnapshot {
        var configuration = ContainerConfiguration(
            id: id,
            image: .init(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        configuration.labels = labels
        return ContainerSnapshot(configuration: configuration, incarnation: "incarnation-\(id)", status: .stopped, networks: [], startedDate: nil)
    }

    static func hub(_ limits: ContainerEventHub.Limits = .init()) -> ContainerEventHub {
        ContainerEventHub(processNonce: "nonce", limits: limits, log: log)
    }

    @Test("events are numbered from 1 without gaps and read in order, with what a filter needs")
    func orderAndShape() async throws {
        let hub = Self.hub()
        let reader = EventCollector(try hub.subscribe(since: nil))
        hub.emit(.create, snapshot: Self.snapshot(labels: ["com.docker.compose.project": "p"]), name: "web")
        hub.emit(.start, snapshot: Self.snapshot(), name: "hub")
        hub.emit(.die, snapshot: Self.snapshot(), name: "hub", exitCode: 3)
        let events = await reader.take(3)
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(EventCollector.actions(events) == ["create", "start", "die"])
        #expect(events[0].labels == ["com.docker.compose.project": "p"])
        #expect(events[0].name == "web")
        #expect(events[0].image == "docker.io/library/alpine:latest")
        #expect(events[0].incarnation == "incarnation-hub")
        #expect(events[2].exitCode == 3)
        // The control: only `die` carries an exit code.
        #expect(events[1].exitCode == nil)
    }

    @Test("a subscriber that reads nothing is closed once it falls behind, and holds no change up; one that reads gets everything")
    func slowSubscriberOverflow() async throws {
        let hub = Self.hub(.init(replayed: 8, queuedEvents: 8, queuedBytes: 1 << 20))
        let stalled = try hub.subscribe(since: nil)
        let reader = EventCollector(try hub.subscribe(since: nil))
        // Big enough that the stalled pipe fills and its queue grows.
        let big = Self.snapshot(labels: ["padding": String(repeating: "x", count: 32 * 1024)])
        let clock = ContinuousClock()
        let began = clock.now
        for count in 1...40 {
            hub.emit(.start, snapshot: big, name: "big")
            // The next only once the reader has this one, so that it never falls behind, however
            // loaded the machine is: only the stalled subscriber can.
            #expect(await reader.waitFor(count))
        }
        // Emitting never waited for the stalled subscriber.
        #expect(clock.now - began < .seconds(20))
        #expect(hub.subscriberCount == 1)
        // The stalled one reads what reached its pipe, then the end of the stream.
        let stalledReader = EventCollector(stalled)
        #expect(await stalledReader.waitForEnd())
        #expect(stalledReader.all.count < 40)
        #expect(stalledReader.all.map(\.sequence) == Array(1...UInt64(stalledReader.all.count)))
        // The control: the subscriber that reads gets every event.
        #expect(await reader.take(40).count == 40)
        #expect(!reader.ended)
    }

    @Test("one subscriber too many closes the oldest")
    func subscriberCap() async throws {
        let hub = Self.hub(.init(subscribers: 2))
        let first = EventCollector(try hub.subscribe(since: nil))
        let second = EventCollector(try hub.subscribe(since: nil))
        #expect(!first.ended)
        let third = EventCollector(try hub.subscribe(since: nil))
        #expect(await first.waitForEnd())
        hub.emit(.create, snapshot: Self.snapshot(), name: "hub")
        #expect(await second.take(1).count == 1)
        #expect(await third.take(1).count == 1)
        #expect(hub.subscriberCount == 2)
    }

    @Test("a subscriber that reconnects with its last event gets what came after it, in order")
    func replay() async throws {
        let hub = Self.hub(.init(replayed: 4))
        for action in [ContainerEvent.Action.create, .start, .die] {
            hub.emit(action, snapshot: Self.snapshot(), name: "hub")
        }
        let subscription = try hub.subscribe(since: ContainerEventCursor(processNonce: "nonce", sequence: 1))
        #expect(!subscription.gap)
        #expect(subscription.replayed == 2)
        #expect(subscription.cursor == 3)
        let reader = EventCollector(subscription)
        hub.emit(.destroy, snapshot: Self.snapshot(), name: "hub")
        let events = await reader.take(3)
        #expect(events.map(\.sequence) == [2, 3, 4])
        #expect(EventCollector.actions(events) == ["start", "die", "destroy"])
    }

    @Test("a subscriber that saw everything gets nothing replayed and no gap")
    func upToDate() throws {
        let hub = Self.hub()
        hub.emit(.create, snapshot: Self.snapshot(), name: "hub")
        let subscription = try hub.subscribe(since: ContainerEventCursor(processNonce: "nonce", sequence: 1))
        #expect(!subscription.gap)
        #expect(subscription.replayed == 0)
        close(subscription.handle.fileDescriptor)
    }

    @Test("a cursor older than what is kept, another process's, or ahead of this one is a gap")
    func gaps() throws {
        let hub = Self.hub(.init(replayed: 2))
        for _ in 0..<5 { hub.emit(.start, snapshot: Self.snapshot(), name: "hub") }
        for (since, gap) in [
            (ContainerEventCursor(processNonce: "nonce", sequence: 1), true),  // 2 is no longer kept
            (ContainerEventCursor(processNonce: "nonce", sequence: 2), true),
            (ContainerEventCursor(processNonce: "nonce", sequence: 3), false),  // 4 and 5 are: the control
            (ContainerEventCursor(processNonce: "another", sequence: 4), true),
            (ContainerEventCursor(processNonce: "nonce", sequence: 9), true),
        ] {
            let subscription = try hub.subscribe(since: since)
            #expect(subscription.gap == gap, "since \(since.sequence) of \(since.processNonce)")
            #expect(subscription.replayed == (gap ? 0 : 2))
            #expect(subscription.cursor == 5)
            close(subscription.handle.fileDescriptor)
        }
    }

    @Test("a replay larger than a subscriber may have queued is a gap, not a subscriber closed at once")
    func replayTooLarge() throws {
        let hub = Self.hub(.init(replayed: 16, queuedEvents: 4))
        for _ in 0..<10 { hub.emit(.start, snapshot: Self.snapshot(), name: "hub") }
        let large = try hub.subscribe(since: ContainerEventCursor(processNonce: "nonce", sequence: 2))
        #expect(large.gap)
        close(large.handle.fileDescriptor)
        let small = try hub.subscribe(since: ContainerEventCursor(processNonce: "nonce", sequence: 7))
        #expect(!small.gap)
        #expect(small.replayed == 3)
        close(small.handle.fileDescriptor)
    }

    @Test("a subscriber that closes its end is dropped at the next event")
    func readerGone() async throws {
        let hub = Self.hub()
        let subscription = try hub.subscribe(since: nil)
        close(subscription.handle.fileDescriptor)
        for _ in 0..<3 {
            hub.emit(.start, snapshot: Self.snapshot(), name: "hub")
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 where hub.subscriberCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hub.subscriberCount == 0)
    }

    @Test("a line cut short by the end of the pipe is not an event, and a line that is not one ends the stream")
    func readerLines() async throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let event = ContainerEvent(
            sequence: 1, timeNano: 1, id: "a", incarnation: "i", action: .create, name: "a", image: "alpine", labels: [:])
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        data.append(contentsOf: Array(#"{"sequence":2,"#.utf8))
        _ = data.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        close(fds[1])
        let reader = EventCollector(ContainerEventLines.events(from: fds[0]))
        #expect(await reader.waitForEnd())
        #expect(reader.all.map(\.sequence) == [1])
        #expect(reader.endError == nil)

        #expect(pipe(&fds) == 0)
        _ = Array("not an event\n".utf8).withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        close(fds[1])
        let malformed = EventCollector(ContainerEventLines.events(from: fds[0]))
        #expect(await malformed.waitForEnd())
        #expect(malformed.endError != nil)
    }

    @Test("an action this client does not know is read as one")
    func unknownAction() throws {
        let line = #"{"sequence":1,"timeNano":1,"id":"a","incarnation":"i","action":"pause","name":"a","image":"x","labels":{},"health":"weird","attributes":{}}"#
        let event = try JSONDecoder().decode(ContainerEvent.self, from: Data(line.utf8))
        #expect(event.action.rawValue == "pause")
        #expect(event.health == nil)
    }
}
