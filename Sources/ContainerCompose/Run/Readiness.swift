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

/// Waiting for a service to be what another one needs it to be: healthy, or finished.
struct Readiness: Sendable {
    /// Seconds since a fixed moment.
    var now: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
    /// The longest a waiting loop goes without looking again.
    var pollInterval: Double = 1

    /// Run the service's health check until it passes.
    ///
    /// The check is given as long as the service's own timing gives it: its start period,
    /// then `retries` intervals. It is tried more often than every interval, because the
    /// point of waiting is to go on as soon as the service is ready, and the first pass
    /// ends the wait. Throws when the time is up, or when the container stops.
    func waitUntilHealthy(_ check: ComposeHealthcheck, service: String, container: String, engine: any ComposeEngine) async throws {
        let started = now()
        let allowance = check.startPeriod + Double(max(check.retries, 1)) * check.interval
        var lastFailure = "it has not been run"
        while true {
            try Task.checkCancellation()
            guard let current = try await engine.container(named: container) else {
                throw ComposeError("service \(service) cannot become healthy: its container \(container) is gone")
            }
            guard current.state != .stopped else {
                throw ComposeError(
                    "service \(service) cannot become healthy: its container \(container) has stopped"
                        + (current.exitCode.map { " with exit code \($0)" } ?? ""))
            }
            do {
                switch try await engine.run(check.test, in: container, timeout: check.timeout) {
                case 0:
                    return
                case .some(let code):
                    lastFailure = "it ended with exit code \(code)"
                case nil:
                    lastFailure = "it did not finish within \(Self.seconds(check.timeout))"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = "it could not be run: \(error)"
            }
            let elapsed = now() - started
            guard elapsed < allowance else {
                throw ComposeError(
                    "service \(service) is not healthy after \(Self.seconds(elapsed)): its check (\(ShellWords.join(check.test))) keeps failing; the last time, \(lastFailure)"
                )
            }
            try await sleep(min(pollInterval, max(check.interval, 0.1), max(allowance - elapsed, 0.1)))
        }
    }

    /// Wait for the service's container to end, and return how it ended.
    func waitUntilExited(service: String, container: String, engine: any ComposeEngine) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            guard let current = try await engine.container(named: container) else {
                throw ComposeError("service \(service) cannot be waited for: its container \(container) is gone")
            }
            if current.state == .stopped {
                guard let exitCode = current.exitCode else {
                    throw ComposeError("service \(service) stopped, and the engine has no record of how its container \(container) ended")
                }
                return exitCode
            }
            try await sleep(min(pollInterval, 0.5))
        }
    }

    static func seconds(_ interval: Double) -> String {
        let rounded = (interval * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return "\(text) second\(rounded == 1 ? "" : "s")"
    }
}
