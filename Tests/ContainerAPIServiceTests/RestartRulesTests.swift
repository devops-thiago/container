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
import Containerization
import Foundation
import Testing

@testable import ContainerAPIService

/// When the engine starts a container again, decided without running one.
struct RestartRulesTests {
    private typealias Policy = ContainerConfiguration.RestartPolicy

    private func restarts(
        _ policy: Policy?,
        _ end: ContainerRunEnd,
        exitRequested: Bool = false,
        stoppedByUser: Bool = false,
        engineShuttingDown: Bool = false,
        restartCount: Int = 0
    ) -> Bool {
        RestartRules.restartsAfterExit(
            policy: policy,
            end: end,
            exitRequested: exitRequested,
            stoppedByUser: stoppedByUser,
            engineShuttingDown: engineShuttingDown,
            restartCount: restartCount)
    }

    @Test("an exit by itself restarts per policy: always and unless-stopped on any code, on-failure on non-zero only")
    func exitTable() {
        let ends: [ContainerRunEnd] = [.exited(0), .exited(1), .exited(137)]
        for end in ends {
            #expect(!restarts(nil, end), "\(end)")
            #expect(!restarts(.no, end), "\(end)")
            #expect(restarts(.always, end), "\(end)")
            #expect(restarts(.unlessStopped, end), "\(end)")
        }
        #expect(!restarts(.onFailure(maxRetries: nil), .exited(0)))
        #expect(restarts(.onFailure(maxRetries: nil), .exited(1)))
        #expect(restarts(.onFailure(maxRetries: nil), .exited(137)))
        #expect(restarts(.onFailure(maxRetries: nil), .exited(-1)))
    }

    @Test("a lost helper is not a failure exit, but always and unless-stopped still come back")
    func lostHelper() {
        #expect(!restarts(.onFailure(maxRetries: nil), .lost))
        #expect(!restarts(.onFailure(maxRetries: 5), .lost))
        #expect(restarts(.always, .lost))
        #expect(restarts(.unlessStopped, .lost))
        #expect(!restarts(.no, .lost))
        #expect(!restarts(nil, .lost))
    }

    @Test("nothing asked to stop is started again, whatever the policy")
    func requestedStops() {
        for policy: Policy in [.always, .unlessStopped, .onFailure(maxRetries: nil)] {
            #expect(!restarts(policy, .stopped), "\(policy)")
            #expect(!restarts(policy, .exited(143), exitRequested: true), "\(policy)")
            #expect(!restarts(policy, .exited(1), exitRequested: true), "\(policy)")
            #expect(!restarts(policy, .lost, exitRequested: true), "\(policy)")
        }
    }

    @Test("nothing ending while the engine goes down is started again")
    func engineShutdown() {
        for policy: Policy in [.always, .unlessStopped, .onFailure(maxRetries: nil)] {
            #expect(!restarts(policy, .exited(1), engineShuttingDown: true), "\(policy)")
            #expect(!restarts(policy, .lost, engineShuttingDown: true), "\(policy)")
        }
    }

    @Test("a person's stop keeps unless-stopped down after a later exit, and not always")
    func stoppedByUser() {
        #expect(!restarts(.unlessStopped, .exited(1), stoppedByUser: true))
        #expect(restarts(.always, .exited(1), stoppedByUser: true))
        #expect(restarts(.onFailure(maxRetries: nil), .exited(1), stoppedByUser: true))
    }

    @Test("on-failure:N gives up once N restarts were made; unset and 0 have no limit")
    func onFailureLimit() {
        #expect(restarts(.onFailure(maxRetries: 3), .exited(1), restartCount: 0))
        #expect(restarts(.onFailure(maxRetries: 3), .exited(1), restartCount: 2))
        #expect(!restarts(.onFailure(maxRetries: 3), .exited(1), restartCount: 3))
        #expect(!restarts(.onFailure(maxRetries: 3), .exited(1), restartCount: 4))
        #expect(restarts(.onFailure(maxRetries: 0), .exited(1), restartCount: 1000))
        #expect(restarts(.onFailure(maxRetries: nil), .exited(1), restartCount: 1000))
        #expect(restarts(.always, .exited(1), restartCount: 1000))
    }

    @Test("the delay starts at 100 ms and doubles up to a minute while the container keeps failing")
    func backoffGrows() {
        var backoff = RestartBackoff()
        let delays = (0..<13).map { _ in backoff.next(ranFor: .seconds(1)) }
        #expect(
            delays == [
                .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800),
                .milliseconds(1600), .milliseconds(3200), .milliseconds(6400), .milliseconds(12800),
                .milliseconds(25600), .milliseconds(51200), .seconds(60), .seconds(60), .seconds(60),
            ])
    }

    @Test("a run of 10 seconds or more starts the delays over; a shorter one does not")
    func backoffResetsAfterAStableRun() {
        var backoff = RestartBackoff()
        for _ in 0..<5 { _ = backoff.next(ranFor: .zero) }
        #expect(backoff.delay == .milliseconds(1600))
        #expect(backoff.next(ranFor: .milliseconds(9999)) == .milliseconds(3200))
        #expect(backoff.next(ranFor: .seconds(10)) == .milliseconds(100))
        #expect(backoff.next(ranFor: .seconds(2)) == .milliseconds(200))
        #expect(backoff.next(ranFor: .seconds(3600)) == .milliseconds(100))
    }

    @Test("a start by hand starts the delays over")
    func backoffReset() {
        var backoff = RestartBackoff()
        for _ in 0..<20 { _ = backoff.next(ranFor: .zero) }
        #expect(backoff.delay == .seconds(60))
        backoff.reset()
        #expect(backoff.delay == .zero)
        #expect(backoff.next(ranFor: .zero) == .milliseconds(100))
    }

    @Test("at engine start: always if ever started, unless-stopped if also not stopped by a person, never the others")
    func bootTable() {
        let started = RestartRecord(stoppedByUser: false, hasBeenStarted: true)
        let stopped = RestartRecord(stoppedByUser: true, hasBeenStarted: true)
        let created = RestartRecord(stoppedByUser: false, hasBeenStarted: false)

        #expect(RestartRules.startsWithEngine(policy: .always, record: started))
        #expect(RestartRules.startsWithEngine(policy: .always, record: stopped))
        #expect(!RestartRules.startsWithEngine(policy: .always, record: created))

        #expect(RestartRules.startsWithEngine(policy: .unlessStopped, record: started))
        #expect(!RestartRules.startsWithEngine(policy: .unlessStopped, record: stopped))
        #expect(!RestartRules.startsWithEngine(policy: .unlessStopped, record: created))

        for policy: Policy? in [nil, .no, .onFailure(maxRetries: nil), .onFailure(maxRetries: 2)] {
            #expect(!RestartRules.startsWithEngine(policy: policy, record: started), "\(String(describing: policy))")
            #expect(!RestartRules.startsWithEngine(policy: policy, record: stopped), "\(String(describing: policy))")
        }
    }

    @Test("a kill ends the restarts for SIGKILL, the stop signal, or any signal without one")
    func killSignals() {
        #expect(RestartRules.signalEndsRestarts(.kill, stopSignal: nil))
        #expect(RestartRules.signalEndsRestarts(.term, stopSignal: nil))
        #expect(RestartRules.signalEndsRestarts(.hup, stopSignal: nil))
        #expect(RestartRules.signalEndsRestarts(.kill, stopSignal: "SIGQUIT"))
        #expect(RestartRules.signalEndsRestarts(.quit, stopSignal: "SIGQUIT"))
        #expect(RestartRules.signalEndsRestarts(.quit, stopSignal: "QUIT"))
        #expect(RestartRules.signalEndsRestarts(.quit, stopSignal: "3"))
        #expect(!RestartRules.signalEndsRestarts(.hup, stopSignal: "SIGQUIT"))
        #expect(!RestartRules.signalEndsRestarts(.term, stopSignal: "SIGQUIT"))
    }
}

/// What the exit monitor reports, which is what tells a failed wait from an exit.
struct ExitMonitorOutcomeTests {
    private struct Dropped: Error {}

    private actor Outcomes {
        var exited: [Int32] = []
        var failed = 0

        func record(_ outcome: ExitMonitor.Outcome) {
            switch outcome {
            case .exited(let status): exited.append(status.exitCode)
            case .waitFailed: failed += 1
            }
        }
    }

    private func deliver(_ wait: @escaping ExitMonitor.WaitHandler) async throws -> (exited: [Int32], failed: Int) {
        let monitor = ExitMonitor()
        let outcomes = Outcomes()
        let (done, signal) = AsyncStream<Void>.makeStream()
        try await monitor.registerProcess(
            id: "c",
            onOutcome: { _, outcome in
                await outcomes.record(outcome)
                signal.yield()
            })
        try await monitor.track(id: "c", waitingOn: wait)
        for await _ in done { break }
        return (await outcomes.exited, await outcomes.failed)
    }

    @Test("an exit is reported with its code")
    func exited() async throws {
        let result = try await deliver { ExitStatus(exitCode: 3) }
        #expect(result.exited == [3])
        #expect(result.failed == 0)
    }

    @Test("a wait that fails is reported as such, not as an exit code")
    func waitFailed() async throws {
        let result = try await deliver { throw Dropped() }
        #expect(result.exited.isEmpty)
        #expect(result.failed == 1)
    }

    @Test("the exit-code callback still sees a failed wait as -1")
    func legacyCallback() async throws {
        let monitor = ExitMonitor()
        let (codes, signal) = AsyncStream<Int32>.makeStream()
        try await monitor.registerProcess(id: "c", onExit: { _, status in signal.yield(status.exitCode) })
        try await monitor.track(id: "c", waitingOn: { throw Dropped() })
        var received: Int32?
        for await code in codes {
            received = code
            break
        }
        #expect(received == -1)
    }
}
