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
import Containerization
import Foundation

/// How one run of a container ended, in the terms its restart policy decides on.
enum ContainerRunEnd: Sendable, Equatable {
    /// The process exited and the runtime reported this code.
    case exited(Int32)
    /// The wait on the runtime helper failed, so how the process ended is not known: the
    /// helper died, or its connection dropped. Not a failure exit for `on-failure`.
    case lost
    /// A stop or a kill ended the run, and no code was reported for it.
    case stopped
}

/// The delay before the engine starts a container again, as Docker's daemon spaces its
/// restarts: 100 ms, doubling at each restart up to a minute, and back to 100 ms after a run
/// that lasted 10 seconds or more.
struct RestartBackoff: Sendable, Equatable {
    static let initialDelay: Duration = .milliseconds(100)
    static let maximumDelay: Duration = .seconds(60)
    /// A run at least this long counts as the container having come up, and the next
    /// restart starts the delays over.
    static let stableRun: Duration = .seconds(10)

    /// The delay used for the last restart; zero before the first.
    private(set) var delay: Duration = .zero

    /// The delay before the next restart, for a run that lasted `ranFor`.
    mutating func next(ranFor: Duration) -> Duration {
        if ranFor >= Self.stableRun {
            delay = .zero
        }
        delay = delay == .zero ? Self.initialDelay : min(delay * 2, Self.maximumDelay)
        return delay
    }

    /// Back to the first delay, for a container started by hand.
    mutating func reset() {
        delay = .zero
    }
}

/// When a container is started again by the engine, with Docker's rules.
enum RestartRules {
    /// Whether a container whose run just ended is started again.
    ///
    /// - Parameters:
    ///   - policy: the container's restart policy; nil is `no`.
    ///   - end: how the run ended.
    ///   - exitRequested: a stop or a kill was asked for this run, by a person or by the
    ///     engine going down. Nothing that was asked to end is started again.
    ///   - stoppedByUser: the persisted mark of a person's stop, which `unless-stopped`
    ///     honours.
    ///   - engineShuttingDown: the engine is going down; a run ending now is part of that.
    ///   - restartCount: restarts so far, which `on-failure:N` compares with N.
    static func restartsAfterExit(
        policy: ContainerConfiguration.RestartPolicy?,
        end: ContainerRunEnd,
        exitRequested: Bool,
        stoppedByUser: Bool,
        engineShuttingDown: Bool,
        restartCount: Int
    ) -> Bool {
        if engineShuttingDown || exitRequested || end == .stopped {
            return false
        }
        switch policy {
        case .none, .no:
            return false
        case .always:
            return true
        case .unlessStopped:
            return !stoppedByUser
        case .onFailure(let maxRetries):
            guard case .exited(let code) = end, code != 0 else { return false }
            // Unset, or 0 as Docker reads it, is no limit.
            guard let maxRetries, maxRetries > 0 else { return true }
            return restartCount < maxRetries
        }
    }

    /// Whether a stopped container is started when the engine starts.
    ///
    /// `always` starts if it has ever been started, even after a person stopped it: that stop
    /// holds only until the engine restarts. `unless-stopped` starts if it has been started
    /// and a person did not stop it. `on-failure` and `no` never start with the engine.
    static func startsWithEngine(policy: ContainerConfiguration.RestartPolicy?, record: RestartRecord) -> Bool {
        guard record.hasBeenStarted else { return false }
        switch policy {
        case .always:
            return true
        case .unlessStopped:
            return !record.stoppedByUser
        case .none, .no, .onFailure:
            return false
        }
    }

    /// Whether a signal sent to a container's process ends its restarts: SIGKILL, the
    /// container's own stop signal, or any signal when it has none, as Docker decides it.
    /// Any signal a person sends counts as their stop for `unless-stopped`.
    static func signalEndsRestarts(_ signal: Signal, stopSignal: String?) -> Bool {
        guard signal != .kill, let stopSignal, let configured = try? Signal(stopSignal) else {
            return true
        }
        return configured == signal
    }
}
