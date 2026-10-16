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

@testable import DockerAPIService

/// The engine as `wait`'s polling sees it, changed by the test.
final class EngineView: Sendable {
    private let state = Mutex<[String: DockerWaitObservation]>([:])

    func set(_ engineID: String, _ observation: DockerWaitObservation?) {
        state.withLock { $0[engineID] = observation }
    }

    func get(_ engineID: String) -> DockerWaitObservation? {
        state.withLock { $0[engineID] }
    }
}

/// A wait being answered in the background, so a test can say it has not been answered yet.
final class PendingWait: Sendable {
    final class Answer: Sendable {
        let value = Mutex<DockerWaitResponse??>(nil)
    }

    private let answer = Answer()
    let task: Task<DockerWaitResponse?, Never>

    init(_ store: DockerWaitStore, _ ticket: DockerWaitTicket) {
        let answer = self.answer
        task = Task {
            let response = await store.response(ticket)
            answer.value.withLock { $0 = .some(response) }
            return response
        }
    }

    /// Whether an answer (or a cancellation) has come within `time`.
    func answered(within time: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: time)
        while ContinuousClock.now < deadline {
            if answer.value.withLock({ $0 != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return answer.value.withLock { $0 != nil }
    }

    var value: DockerWaitResponse? {
        get async { await task.value }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DockerWaitStoreTests {
    static let running = DockerWaitObservation(running: true, startedAt: Fixtures.now)
    static func stopped(_ code: Int32, at offset: TimeInterval = 0) -> DockerWaitObservation {
        DockerWaitObservation(running: false, exitCode: code, startedAt: Fixtures.now, exitedAt: Fixtures.now.addingTimeInterval(10 + offset))
    }

    static func store(_ view: EngineView, poll: Duration = .milliseconds(10), limits: DockerWaitLimits? = nil) -> DockerWaitStore {
        DockerWaitStore(limits: limits ?? DockerWaitLimits(pollInterval: poll)) { view.get($0) }
    }

    @Test("not-running answers at once for a stopped container, and a running one's at its exit")
    func notRunning() async throws {
        let view = EngineView()
        let store = Self.store(view)
        view.set("done", Self.stopped(3))
        let immediate = try await store.register(engineID: "done", condition: .notRunning, observed: Self.stopped(3))
        #expect(await store.response(immediate) == DockerWaitResponse(statusCode: 3))
        // Control: a running container's not-running waits for its exit.
        view.set("web", Self.running)
        let later = PendingWait(store, try await store.register(engineID: "web", condition: .notRunning, observed: Self.running))
        #expect(await !later.answered(within: .milliseconds(80)))
        view.set("web", Self.stopped(4))
        #expect(await later.value == DockerWaitResponse(statusCode: 4))
        #expect(await store.pending == 0)
        #expect(await store.polling == 0)
    }

    @Test("next-exit waits for the next exit even when the container is stopped now")
    func nextExit() async throws {
        let view = EngineView()
        let store = Self.store(view, poll: .seconds(3600))
        await store.starting("web")
        await store.exited("web", code: 5)
        let next = PendingWait(store, try await store.register(engineID: "web", condition: .nextExit, observed: Self.stopped(5)))
        #expect(await !next.answered(within: .milliseconds(80)))
        // Control: not-running on the same stopped container answers at once, with the last exit.
        let now = try await store.register(engineID: "web", condition: .notRunning, observed: Self.stopped(5))
        #expect(await store.response(now) == DockerWaitResponse(statusCode: 5))
        await store.starting("web")
        await store.exited("web", code: 9)
        #expect(await next.value == DockerWaitResponse(statusCode: 9))
    }

    @Test("an exit between the route's look at the container and the registration is not lost")
    func exitBeforeRegistration() async throws {
        // Polling that never comes: only the store's own state can answer.
        let view = EngineView()
        let store = Self.store(view, poll: .seconds(3600))
        for code in Int32(0)..<30 {
            await store.starting("web")
            // The route saw it running; the process exits before the wait is registered.
            await store.exited("web", code: code)
            let ticket = try await store.register(engineID: "web", condition: .notRunning, observed: Self.running)
            #expect(await store.response(ticket) == DockerWaitResponse(statusCode: code))
        }
        // Control: for a container this service did not start, the same stale look leaves the
        // wait to polling, which here never comes.
        let foreign = PendingWait(store, try await store.register(engineID: "other", condition: .notRunning, observed: Self.running))
        #expect(await !foreign.answered(within: .milliseconds(50)))
        foreign.task.cancel()
    }

    @Test("a registration racing an immediate exit is answered with that exit, 30 times over")
    func registrationRace() async throws {
        let view = EngineView()
        let store = Self.store(view, poll: .seconds(3600))
        for code in Int32(0)..<30 {
            let engineID = "race\(code)"
            await store.starting(engineID)
            // The process exits at once while the wait registers: whichever comes first, the
            // wait hears this exit.
            async let exit: Void = store.exited(engineID, code: code)
            async let ticket = store.register(engineID: engineID, condition: .notRunning, observed: Self.running)
            _ = await exit
            #expect(await store.response(try ticket) == DockerWaitResponse(statusCode: code))
        }
        #expect(await store.pending == 0)
    }

    @Test("a failed start answers next-exit and not-running with the error body")
    func failedStart() async throws {
        let view = EngineView()
        let store = Self.store(view, poll: .seconds(3600))
        let created = DockerWaitObservation(running: false)
        let next = PendingWait(store, try await store.register(engineID: "web", condition: .nextExit, observed: created))
        await store.starting("web")
        await store.startFailed("web", message: "no such file: /bin/nope")
        let failed = try #require(await next.value)
        #expect(failed == DockerWaitResponse(statusCode: 128, error: "no such file: /bin/nope"))
        let json = try #require(try JSONSerialization.jsonObject(with: DockerJSON.encoder.encode(failed)) as? [String: Any])
        #expect(json["StatusCode"] as? Int == 128)
        #expect((json["Error"] as? [String: Any])?["Message"] as? String == "no such file: /bin/nope")
        // Control: a clean exit has no Error at all.
        await store.starting("web")
        let clean = PendingWait(store, try await store.register(engineID: "web", condition: .nextExit, observed: Self.running))
        await store.exited("web", code: 0)
        let ok = try #require(await clean.value)
        #expect(String(data: try DockerJSON.encoder.encode(ok), encoding: .utf8) == #"{"StatusCode":0}"#)
    }

    @Test("removed answers at the deletion, not at the exit, with the last exit status")
    func removed() async throws {
        let view = EngineView()
        let store = Self.store(view, poll: .seconds(3600))
        await store.starting("web")
        view.set("web", Self.running)
        let removal = PendingWait(store, try await store.register(engineID: "web", condition: .removed, observed: Self.running))
        let exit = PendingWait(store, try await store.register(engineID: "web", condition: .nextExit, observed: Self.running))
        await store.exited("web", code: 2)
        // Control: the exit answers next-exit, and not removed.
        #expect(await exit.value == DockerWaitResponse(statusCode: 2))
        #expect(await !removal.answered(within: .milliseconds(50)))
        await store.removed("web")
        #expect(await removal.value == DockerWaitResponse(statusCode: 2))
    }

    @Test("a deletion that kills the running process answers removed with that exit, or after a grace without it")
    func removedBeforeExit() async throws {
        let view = EngineView()
        let store = Self.store(view, limits: DockerWaitLimits(pollInterval: .seconds(3600), removalGrace: .milliseconds(150)))
        await store.starting("web")
        let removal = PendingWait(store, try await store.register(engineID: "web", condition: .removed, observed: Self.running))
        // rm -f: the route publishes the deletion before the monitor publishes the exit.
        await store.removed("web")
        #expect(await !removal.answered(within: .milliseconds(40)))
        await store.exited("web", code: 137)
        #expect(await removal.value == DockerWaitResponse(statusCode: 137))
        // Control: a process whose exit never comes is answered after the grace, with what is known.
        await store.starting("db")
        let stuck = PendingWait(store, try await store.register(engineID: "db", condition: .removed, observed: Self.running))
        await store.removed("db")
        #expect(await stuck.value == DockerWaitResponse(statusCode: 0))
        #expect(await store.pending == 0)
    }

    @Test("a removal the engine makes on its own (--rm) is seen by polling once the process exited")
    func autoRemoved() async throws {
        let view = EngineView()
        let store = Self.store(view)
        await store.starting("web")
        view.set("web", Self.running)
        let removal = PendingWait(store, try await store.register(engineID: "web", condition: .removed, observed: Self.running))
        // Nothing is polled while the process this service started runs.
        #expect(await store.polling == 0)
        await store.exited("web", code: 7)
        view.set("web", Self.stopped(7))
        // Control: stopped but still there, so not removed.
        #expect(await !removal.answered(within: .milliseconds(60)))
        view.set("web", nil)
        #expect(await removal.value == DockerWaitResponse(statusCode: 7))
        #expect(await store.polling == 0)
    }

    @Test("a container this service did not start is followed by polling, next-exit included")
    func foreignNextExit() async throws {
        let view = EngineView()
        let store = Self.store(view)
        view.set("cli", Self.stopped(1))
        let next = PendingWait(store, try await store.register(engineID: "cli", condition: .nextExit, observed: Self.stopped(1)))
        // Control: polling the same stopped container does not count as an exit.
        #expect(await !next.answered(within: .milliseconds(60)))
        // Started and stopped again between two looks: a new exit time is a new exit.
        view.set("cli", Self.stopped(6, at: 5))
        #expect(await next.value == DockerWaitResponse(statusCode: 6))
    }

    @Test("a wait whose client left is forgotten, and its polling stops")
    func cancellation() async throws {
        let view = EngineView()
        let store = Self.store(view)
        view.set("web", Self.running)
        let kept = PendingWait(store, try await store.register(engineID: "web", condition: .notRunning, observed: Self.running))
        let left = PendingWait(store, try await store.register(engineID: "web", condition: .notRunning, observed: Self.running))
        #expect(await store.pending == 2)
        left.task.cancel()
        #expect(await left.value == nil)
        // Control: the other wait is still pending, and still polled.
        #expect(await store.pending == 1)
        #expect(await store.polling == 1)
        kept.task.cancel()
        _ = await kept.value
        #expect(await store.pending == 0)
        #expect(await store.polling == 0)
    }

    @Test("waits are bounded per container and overall, and end on shutdown")
    func limits() async throws {
        let view = EngineView()
        let store = Self.store(view, limits: DockerWaitLimits(perContainer: 2, total: 3, pollInterval: .seconds(3600)))
        _ = try await store.register(engineID: "a", condition: .removed, observed: Self.running)
        let second = try await store.register(engineID: "a", condition: .removed, observed: Self.running)
        await #expect(throws: DockerAPIError.self) { try await store.register(engineID: "a", condition: .removed, observed: Self.running) }
        // Control: another container still has room, up to the overall cap.
        _ = try await store.register(engineID: "b", condition: .removed, observed: Self.running)
        await #expect(throws: DockerAPIError.self) { try await store.register(engineID: "c", condition: .removed, observed: Self.running) }
        let pending = PendingWait(store, second)
        await store.shutdown()
        #expect(await pending.value == nil)
        #expect(await store.pending == 0)
    }
}
