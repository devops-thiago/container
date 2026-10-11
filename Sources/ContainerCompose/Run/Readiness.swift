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

/// Waiting for a service to be what another one needs it to be: healthy, or finished.
struct Readiness: Sendable {
    var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
    /// The longest a waiting loop goes without looking again.
    var pollInterval: Double = 1

    /// Wait until the engine reports the service's container healthy.
    ///
    /// The engine runs the check, on the schedule the check gives, and keeps the result; this
    /// only looks at it, every `pollInterval`. It ends as Docker's compose ends it: healthy
    /// goes on, unhealthy fails, and so does a container that stops, goes away, or turns out
    /// to have no health check at all. While the check is starting, it waits: the check's own
    /// retries and start period decide how long that lasts.
    func waitUntilHealthy(service: String, container: String, engine: any ComposeEngine) async throws {
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
            switch current.health?.status {
            case .healthy:
                return
            case .unhealthy:
                throw ComposeError("service \(service) is unhealthy: " + Self.describe(current.health))
            case .starting:
                break
            case nil:
                // A container being started or restarted has not been given its check yet.
                guard current.state != .running else {
                    throw ComposeError(
                        "service \(service) has no health check to wait for: neither its healthcheck nor its image's HEALTHCHECK gives one")
                }
            }
            try await sleep(pollInterval)
        }
    }

    /// The failures that made a container unhealthy, in words.
    static func describe(_ health: ContainerHealth?) -> String {
        guard let health, let last = health.log.last else { return "its health check failed" }
        let times = health.failingStreak == 1 ? "once" : "\(health.failingStreak) times in a row"
        let ended = last.exitCode == -1 ? "it did not run to completion" : "it ended with exit code \(last.exitCode)"
        let output = last.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "its health check failed \(times); the last time, \(ended)" + (output.isEmpty ? "" : ": \(output)")
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
}
