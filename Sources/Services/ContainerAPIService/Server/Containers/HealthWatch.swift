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

/// How the apiserver keeps a running container's health current: one wait at a time on
/// the runtime helper, which answers when a check has been recorded. So `ls` and `inspect`
/// read health from the apiserver's own snapshot, and no list asks every helper.
enum HealthWatch {
    /// Follow one run's health until the run stops checking, a wait fails (the helper went
    /// away with its run), `apply` says the run is no longer the container's, or the task is
    /// cancelled. An answer that is not newer than the last also ends it, rather than ask
    /// again at once for ever.
    static func follow(
        wait: @Sendable (_ after: UInt64) async throws -> HealthUpdate,
        apply: @Sendable (HealthUpdate) async -> Bool
    ) async {
        var generation: UInt64 = 0
        while !Task.isCancelled {
            let update: HealthUpdate
            do {
                update = try await wait(generation)
            } catch {
                return
            }
            guard !Task.isCancelled, await apply(update), !update.finished, update.generation > generation else {
                return
            }
            generation = update.generation
        }
    }

    /// Take an update for `run` into the container's snapshot, if that run is still the
    /// container's current one and it is running. Returns whether it was, which is whether
    /// the run is still worth following.
    static func apply(
        _ update: HealthUpdate,
        to snapshot: inout ContainerSnapshot,
        currentRun: UUID?,
        run: UUID,
        incarnation: String,
        earlierLog: [HealthCheckResult]
    ) -> Bool {
        guard snapshot.incarnation == incarnation, currentRun == run, snapshot.status == .running else { return false }
        if let health = update.health {
            snapshot.health = merged(health, earlierLog: earlierLog)
        }
        return true
    }

    /// The health the engine shows for a run: what the helper reports, with the results
    /// of earlier runs before this run's, the last `ContainerHealth.maximumLogEntries` of
    /// them, as Docker keeps its log across restarts.
    static func merged(_ current: ContainerHealth, earlierLog: [HealthCheckResult]) -> ContainerHealth {
        var health = current
        health.log = Array((earlierLog + current.log).suffix(ContainerHealth.maximumLogEntries))
        return health
    }

    /// The health a run starts with: starting, no streak, the log of earlier runs.
    static func starting(after previous: ContainerHealth?) -> ContainerHealth {
        ContainerHealth(status: .starting, failingStreak: 0, log: previous?.log ?? [])
    }

    /// The health a run leaves behind. Docker marks a check that stops with its container
    /// unhealthy, and that is what `inspect` shows of a stopped container that had one.
    static func ended(_ health: ContainerHealth?) -> ContainerHealth? {
        guard var health else { return nil }
        health.status = .unhealthy
        return health
    }
}
