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
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

/// Time that moves only when the monitor sleeps or a check runs, and a script of what the
/// checks come to. Nothing in these tests waits on a real clock or a guest.
private final class Script: Sendable {
    private struct State {
        var now: Duration = .zero
        var sleeps: [Duration] = []
        var outcomes: [HealthMonitor.Outcome]
        var probes: [(command: [String], timeout: Duration, at: Duration)] = []
    }

    private let state: Mutex<State>
    /// How long each check takes.
    private let checkTakes: Duration

    init(_ outcomes: [HealthMonitor.Outcome], checkTakes: Duration = .milliseconds(100)) {
        self.state = Mutex(State(outcomes: outcomes))
        self.checkTakes = checkTakes
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }
    var probes: [(command: [String], timeout: Duration, at: Duration)] { state.withLock { $0.probes } }

    /// Advances the clock; once the script has run out, the monitor's wait is cancelled,
    /// which is how a run whose checks are all spent ends here.
    func sleep(_ duration: Duration) throws {
        try state.withLock { state in
            guard !state.outcomes.isEmpty else { throw CancellationError() }
            state.sleeps.append(duration)
            state.now += duration
        }
    }

    func probe(_ command: [String], _ timeout: Duration) -> HealthMonitor.Outcome {
        state.withLock { state in
            state.probes.append((command, timeout, state.now))
            state.now += checkTakes
            return state.outcomes.removeFirst()
        }
    }

    func elapsed() -> Duration { state.withLock { $0.now } }

    func monitor(_ check: HealthCheckConfiguration) throws -> HealthMonitor {
        let monitor = HealthMonitor(
            check: check,
            probe: { [self] command, timeout in self.probe(command, timeout) },
            sleep: { [self] duration in try self.sleep(duration) },
            elapsed: { [self] in self.elapsed() },
            now: { [self] in Date(timeIntervalSince1970: TimeInterval(self.elapsed().components.seconds)) })
        return try #require(monitor)
    }
}

private let pass = HealthMonitor.Outcome(exitCode: 0, output: "ok")
private let fail = HealthMonitor.Outcome(exitCode: 1, output: "connection refused")

/// Wait until the monitor has recorded `count` checks.
private func checks(_ count: UInt64, of monitor: HealthMonitor) async -> HealthUpdate {
    var update = await monitor.update
    while update.generation < count, !update.finished {
        update = await monitor.wait(after: update.generation)
    }
    return update
}

struct HealthMonitorTests {
    private let second: Int64 = 1_000_000_000

    @Test func aCheckWithNothingToRunMakesNoMonitor() {
        let disabled = HealthMonitor(check: .disabled, probe: { _, _ in pass }, elapsed: { .zero })
        #expect(disabled == nil)
        let timingOnly = HealthMonitor(check: HealthCheckConfiguration(interval: 1), probe: { _, _ in pass }, elapsed: { .zero })
        #expect(timingOnly == nil)
    }

    /// Run a monitor through a whole script, and return where the checks left it. Once the
    /// script is spent the monitor's next wait is cancelled, so nothing changes after this.
    private func run(_ outcomes: [HealthMonitor.Outcome], _ check: HealthCheckConfiguration) async throws -> (HealthUpdate, Script) {
        let script = Script(outcomes)
        let monitor = try script.monitor(check)
        await monitor.start()
        let update = await checks(UInt64(outcomes.count), of: monitor)
        await monitor.stop()
        #expect(await monitor.update.finished)
        return (update, script)
    }

    @Test func passingThenFailingRetriesTimesIsUnhealthy() async throws {
        // As the issue's acceptance runs it: every 2 s, three retries.
        let check = HealthCheckConfiguration(test: ["CMD-SHELL", "wget -qO- localhost"], interval: 2 * second)

        let (healthy, script) = try await run([pass], check)
        #expect(healthy.health?.status == .healthy)
        #expect(script.sleeps == [.seconds(2)], "one interval before the first check")
        #expect(script.probes.first?.command == ["/bin/sh", "-c", "wget -qO- localhost"])
        #expect(script.probes.first?.timeout == .seconds(30))

        let (oneFailure, _) = try await run([pass, pass, fail], check)
        #expect(oneFailure.health?.status == .healthy, "one failure does not undo a pass")
        #expect(oneFailure.health?.failingStreak == 1)

        let (unhealthy, failing) = try await run([pass, pass, fail, fail, fail], check)
        #expect(unhealthy.health?.status == .unhealthy)
        #expect(unhealthy.health?.failingStreak == 3)
        #expect(unhealthy.health?.log.count == 5)
        #expect(unhealthy.health?.log.last?.output == "connection refused")
        #expect(failing.sleeps == Array(repeating: .seconds(2), count: 5), "an interval between checks")
    }

    @Test func theStartPeriodShieldsFailuresAndRunsAtTheStartInterval() async throws {
        let check = HealthCheckConfiguration(
            test: ["CMD", "pg_isready"], interval: 2 * second, startPeriod: 10 * second, startInterval: 3 * second, retries: 1)

        // Checks at 3 s, 6.1 s and 9.2 s, all in the period: not counted, even with retries 1.
        let (shielded, _) = try await run([fail, fail, fail], check)
        #expect(shielded.health?.status == .starting)
        #expect(shielded.health?.failingStreak == 0)

        // The fourth is at 10 s, the end of the period, and passes; past it, one failure is retries.
        let (after, script) = try await run([fail, fail, fail, pass, fail], check)
        #expect(after.health?.status == .unhealthy)
        #expect(after.health?.failingStreak == 1)
        #expect(script.sleeps == [.seconds(3), .seconds(3), .seconds(3), .milliseconds(700), .seconds(2)], "the period's end, then the interval")
    }

    @Test func theStartIntervalStopsAtTheEndOfThePeriod() async throws {
        let script = Script([fail, fail])
        let check = HealthCheckConfiguration(test: ["CMD", "x"], interval: 30 * second, startPeriod: 4 * second, startInterval: 3 * second)
        let monitor = try script.monitor(check)
        await monitor.start()
        _ = await checks(2, of: monitor)
        #expect(script.sleeps == [.seconds(3), .milliseconds(900)], "what is left of the period, not a whole start interval")
        await monitor.stop()
    }

    @Test func aCheckThatCannotRunIsAFailureNotACrash() async throws {
        let missingShell = HealthMonitor.Outcome(exitCode: -1, output: "the health check could not be run: exec: \"/bin/sh\": no such file or directory")
        let script = Script([missingShell, missingShell, missingShell])
        let monitor = try script.monitor(HealthCheckConfiguration(test: ["CMD-SHELL", "true"], interval: second))
        await monitor.start()
        let update = await checks(3, of: monitor)
        #expect(update.health?.status == .unhealthy)
        #expect(update.health?.log.last?.exitCode == -1)
        #expect(update.health?.log.last?.output.contains("/bin/sh") == true)
        await monitor.stop()
    }

    @Test func stopAnswersEveryWaitAndDropsTheCheckUnderWay() async throws {
        let gate = Gate()
        let started = Gate()
        let made = HealthMonitor(
            check: HealthCheckConfiguration(test: ["CMD", "sleep", "60"]),
            probe: { _, _ in
                await started.open()
                await gate.wait()
                return pass
            },
            sleep: { _ in },
            elapsed: { .zero })
        let monitor = try #require(made)
        await monitor.start()
        async let waited = monitor.wait(after: 0)
        await started.wait()
        await monitor.stop()
        let answer = await waited
        #expect(answer.finished)
        #expect(answer.generation == 0)
        await gate.open()
        // The check comes back after the stop, and is not recorded.
        let later = await monitor.wait(after: 0)
        #expect(later.finished)
        #expect(later.generation == 0)
        #expect(later.health?.status == .starting)
        await monitor.start()
        #expect(await monitor.update.finished, "a stopped monitor stays stopped")
    }

    @Test func aWaitPastTheLatestReturnsAtTheNextCheck() async throws {
        let script = Script([pass, fail])
        let monitor = try script.monitor(HealthCheckConfiguration(test: ["CMD", "x"], interval: second))
        let early = await monitor.update
        #expect(early.generation == 0)
        #expect(!early.finished)
        await monitor.start()
        let first = await monitor.wait(after: 0)
        #expect(first.generation >= 1)
        let behind = await monitor.wait(after: 0)
        #expect(behind.generation >= 1, "a wait behind the latest returns at once")
        await monitor.stop()
    }
}

struct HealthProbeTests {
    @Test func aCheckThatEndsInTimeReportsItsCode() async throws {
        let code = try await HealthProbe.wait(
            timeout: .seconds(30),
            sleep: { try await Task.sleep(for: $0) },
            for: { Int32(7) },
            onTimeout: { Issue.record("no timeout expected") })
        #expect(code == 7)
    }

    @Test func aCheckThatRunsPastItsTimeoutIsKilledAndWaitedFor() async throws {
        let killed = Gate()
        let ended = Mutex(false)
        let code = try await HealthProbe.wait(
            timeout: .seconds(30),
            sleep: { _ in },
            for: { () async -> Int32 in
                await killed.wait()
                ended.withLock { $0 = true }
                return 137
            },
            onTimeout: { await killed.open() })
        #expect(code == nil)
        #expect(ended.withLock { $0 }, "the check had ended by the time the wait returned")
        #expect(HealthProbe.timeoutOutput(.seconds(2), output: "") == "Health check exceeded timeout (2s)")
        #expect(HealthProbe.timeoutOutput(.milliseconds(500), output: "partial") == "Health check exceeded timeout (500ms): partial")
    }

    @Test func outputAndErrorsAreKeptToFourKilobytes() throws {
        let output = HealthOutput()
        try output.write(Data("out ".utf8))
        try output.write(Data("err".utf8))
        #expect(output.text == "out err")
        try output.write(Data(repeating: UInt8(ascii: "x"), count: 5000))
        #expect(output.text.hasSuffix("..."))
        #expect(output.text.utf8.count == 4096 + 3)
    }
}

/// A one-shot latch for ordering steps in these tests.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
