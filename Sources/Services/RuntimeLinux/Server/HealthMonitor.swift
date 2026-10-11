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
import Synchronization

/// Runs one container's health check for one run of it, on Docker's schedule, and keeps
/// what the checks come to.
///
/// The runtime helper makes one when the container's process starts and stops it before
/// the container stops, whichever way it stops; a run that ends takes its helper, and so
/// its monitor, with it. The waiting, the check and the clock are passed in, so the
/// schedule and the state are tested without a guest and without waiting.
actor HealthMonitor {
    /// What one check came to: its exit code, and its output or why it could not be run.
    struct Outcome: Sendable, Equatable {
        var exitCode: Int32
        var output: String
    }

    /// Run the check's command in the guest, giving up after the timeout. Never throws: a
    /// check that cannot be run is a failed check, with the reason as its output.
    typealias Probe = @Sendable (_ command: [String], _ timeout: Duration) async -> Outcome
    typealias Sleep = @Sendable (Duration) async throws -> Void
    /// How long the container has been running.
    typealias Elapsed = @Sendable () -> Duration
    typealias Now = @Sendable () -> Date

    private let check: HealthCheckConfiguration
    private let command: [String]
    private let probe: Probe
    private let sleep: Sleep
    private let elapsed: Elapsed
    private let now: Now

    private var health = ContainerHealth()
    private var generation: UInt64 = 0
    private var finished = false
    private var waiters: [(after: UInt64, continuation: CheckedContinuation<HealthUpdate, Never>)] = []
    private var task: Task<Void, Never>?

    /// Nil when the check has nothing to run.
    init?(
        check: HealthCheckConfiguration,
        probe: @escaping Probe,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        elapsed: @escaping Elapsed,
        now: @escaping Now = { Date() }
    ) {
        guard let command = check.command else { return nil }
        self.check = check
        self.command = command
        self.probe = probe
        self.sleep = sleep
        self.elapsed = elapsed
        self.now = now
    }

    /// The health as the checks so far have left it.
    var update: HealthUpdate {
        HealthUpdate(health: health, generation: generation, finished: finished)
    }

    /// Start checking. Once only: a stopped monitor stays stopped.
    func start() {
        guard task == nil, !finished else { return }
        task = Task { await self.run() }
    }

    /// Stop checking, and answer every wait. A check under way is abandoned: whatever it
    /// comes to is not recorded, as the container is going away.
    func stop() {
        finished = true
        task?.cancel()
        task = nil
        resumeWaiters()
    }

    /// Return once more than `generation` checks have been recorded, or the monitor has
    /// stopped; at once if either is so already.
    func wait(after generation: UInt64) async -> HealthUpdate {
        if finished || self.generation > generation {
            return update
        }
        return await withCheckedContinuation { continuation in
            waiters.append((generation, continuation))
        }
    }

    private func run() async {
        while !finished {
            let delay = ContainerHealth.delayBeforeNextCheck(status: health.status, sinceStart: elapsed(), check: check)
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !finished, !Task.isCancelled else { return }
            let sinceStart = elapsed()
            let start = now()
            let outcome = await probe(command, check.effectiveTimeout)
            guard !finished, !Task.isCancelled else { return }
            record(HealthCheckResult(start: start, end: now(), exitCode: outcome.exitCode, output: outcome.output), sinceStart: sinceStart)
        }
    }

    private func record(_ result: HealthCheckResult, sinceStart: Duration) {
        health.record(result, sinceStart: sinceStart, startPeriod: check.effectiveStartPeriod, retries: check.effectiveRetries)
        generation += 1
        resumeWaiters()
    }

    private func resumeWaiters() {
        let current = update
        var waiting: [(after: UInt64, continuation: CheckedContinuation<HealthUpdate, Never>)] = []
        for waiter in waiters {
            if finished || current.generation > waiter.after {
                waiter.continuation.resume(returning: current)
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }
}

/// The parts of one check that do not need a guest: the race with its timeout, and the
/// output it keeps.
enum HealthProbe {
    /// Wait for `wait`, unless `timeout` passes first. Then `onTimeout` runs, which is to
    /// kill the check, and the wait goes on until the check has ended, so that dying checks
    /// do not pile up. Returns nil when the timeout came first, whatever the killed check
    /// then reports.
    static func wait<T: Sendable>(
        timeout: Duration,
        sleep: @escaping HealthMonitor.Sleep,
        for wait: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws -> T? {
        let timedOut = TimeoutFlag()
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await wait() }
            group.addTask {
                try await sleep(timeout)
                timedOut.set()
                await onTimeout()
                return nil
            }
            let first: T?
            do {
                first = try await group.next() ?? nil
            } catch  where timedOut.isSet {
                first = nil
            }
            if timedOut.isSet {
                while (try? await group.next()) != nil {}
                return nil
            }
            group.cancelAll()
            return first
        }
    }

    private final class TimeoutFlag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// What a check that ran past its timeout reports, as Docker words it.
    static func timeoutOutput(_ timeout: Duration, output: String) -> String {
        let reason = "Health check exceeded timeout (\(HealthCheckConfiguration.format(timeout)))"
        return output.isEmpty ? reason : "\(reason): \(output)"
    }
}

/// Where a check's output and errors go: the first `ContainerHealth.maximumOutputBytes` of
/// both together are kept, and the rest is dropped and noted.
final class HealthOutput: Writer, Sendable {
    private struct State {
        var data = Data()
        var truncated = false
    }

    private let state = Mutex(State())

    func write(_ data: Data) throws {
        state.withLock { state in
            let room = ContainerHealth.maximumOutputBytes - state.data.count
            if room > 0 {
                state.data.append(data.prefix(room))
            }
            if data.count > max(room, 0) {
                state.truncated = true
            }
        }
    }

    func close() throws {}

    var text: String {
        state.withLock { ContainerHealth.keptOutput($0.data, truncated: $0.truncated) }
    }
}
