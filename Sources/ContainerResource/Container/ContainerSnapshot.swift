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

import ContainerizationOCI
import Foundation

/// A snapshot of a container along with its configuration
/// and any runtime state information.
public struct ContainerSnapshot: Codable, Sendable {
    /// The configuration of the container.
    public var configuration: ContainerConfiguration

    /// An opaque identity for this exact creation of `id`.
    ///
    /// The API server generates and persists this value outside the user-supplied
    /// configuration. Clients can carry it back as a mutation precondition, while labels
    /// remain descriptive metadata and cannot impersonate a previous incarnation.
    public let incarnation: String

    /// Identifier of the container.
    public var id: String {
        configuration.id
    }

    /// Configured platform for the container.
    public var platform: ContainerizationOCI.Platform {
        configuration.platform
    }

    /// The runtime status of the container.
    public var status: RuntimeStatus
    /// Network interfaces attached to the sandbox that are provided to the container.
    public var networks: [Attachment]
    /// When the container was started.
    public var startedDate: Date?
    /// The exit code of the container's initial process, once it has exited.
    ///
    /// The engine already knew this — the runtime reports it and ExitMonitor
    /// acts on it — but it was dropped on the floor, so a stopped container was
    /// indistinguishable from one that had failed. `nil` while running, and for
    /// containers that were already stopped before the apiserver started.
    public var exitCode: Int32?
    /// When the container's initial process exited.
    public var exitedAt: Date?
    /// How many times the engine has started the container again under its restart policy
    /// since it was last started by hand, as Docker's `RestartCount` counts.
    public var restartCount: Int
    /// Why the engine could not start the container again, at an exit or when the engine
    /// started, when its restart policy asked it to. Nil once the container starts. Kept by
    /// this apiserver only: the next engine start tries again.
    public var restartError: String?
    /// The container's health, when it has a health check and has been started with it:
    /// Docker's `State.Health`. Reset to starting at each start; unhealthy once the run ends,
    /// as Docker leaves it. Kept by this apiserver only, as runs do not outlive it.
    public var health: ContainerHealth?
    /// Whether the last run ended because a stop or a kill was asked for it, by a person or
    /// by the engine going down, as opposed to its process ending by itself (a crash, an
    /// out-of-memory kill, a normal exit). A stop records 143 or 137 as Docker does, and this
    /// tells such an exit from a failure with the same code. A signal other than SIGKILL
    /// counts only when the exit shows that signal ended the process. False while a run is
    /// under way, after a restart under the restart policy, and when a stop only cancels the
    /// restart delay of a run that had already ended by itself. Nil from an engine that does
    /// not say, and in snapshots or exit records written before it did: not known.
    public var stopRequested: Bool?
    /// Whether the kernel's OOM killer killed a process in the container since it last
    /// started, as Docker's `State.OOMKilled` says: the container's initial process, which
    /// ends the run with 137, or another of its processes. Known once a run has ended; false
    /// from a start until then. Nil from an engine that does not say, and in snapshots or exit
    /// records written before it did.
    public var oomKilled: Bool?

    public init(
        configuration: ContainerConfiguration,
        incarnation: String = "",
        status: RuntimeStatus,
        networks: [Attachment],
        startedDate: Date? = nil,
        exitCode: Int32? = nil,
        exitedAt: Date? = nil,
        restartCount: Int = 0,
        restartError: String? = nil,
        health: ContainerHealth? = nil,
        stopRequested: Bool? = nil,
        oomKilled: Bool? = nil
    ) {
        self.configuration = configuration
        self.incarnation = incarnation
        self.status = status
        self.networks = networks
        self.startedDate = startedDate
        self.exitCode = exitCode
        self.exitedAt = exitedAt
        self.restartCount = restartCount
        self.restartError = restartError
        self.health = health
        self.stopRequested = stopRequested
        self.oomKilled = oomKilled
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case incarnation
        case status
        case networks
        case startedDate
        case exitCode
        case exitedAt
        case restartCount
        case restartError
        case health
        case stopRequested
        case oomKilled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(ContainerConfiguration.self, forKey: .configuration)
        // Runtime helpers and older API servers did not emit an incarnation. Only the API
        // server's persisted snapshots are mutation targets, and it always fills this field.
        incarnation = try container.decodeIfPresent(String.self, forKey: .incarnation) ?? ""
        status = try container.decode(RuntimeStatus.self, forKey: .status)
        networks = try container.decode([Attachment].self, forKey: .networks)
        startedDate = try container.decodeIfPresent(Date.self, forKey: .startedDate)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        exitedAt = try container.decodeIfPresent(Date.self, forKey: .exitedAt)
        restartCount = try container.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
        restartError = try container.decodeIfPresent(String.self, forKey: .restartError)
        health = try container.decodeIfPresent(ContainerHealth.self, forKey: .health)
        stopRequested = try container.decodeIfPresent(Bool.self, forKey: .stopRequested)
        oomKilled = try container.decodeIfPresent(Bool.self, forKey: .oomKilled)
    }
}

extension ContainerSnapshot {
    /// Whether `self`, a later look at the container, still shows the run `run` was taken in.
    ///
    /// A followed log ends with its run, as Docker's does: dockerd closes a container's log
    /// at every exit, one a restart policy follows included, and a follower ends once it has
    /// read what was written before that. A container that is being stopped still writes, so it
    /// is still in its run; one that has stopped, is waiting to restart, was started again since
    /// (a new start time), or is another one made under the same ID (a new incarnation) is not.
    public func isInRun(of run: ContainerSnapshot) -> Bool {
        hasLiveProcess && run.hasLiveProcess && incarnation == run.incarnation && startedDate == run.startedDate
    }

    /// Its process runs, and may still write: running, or being stopped.
    public var hasLiveProcess: Bool {
        status == .running || status == .stopping
    }

    /// The run a follow of a container's log follows, and the cursor `start` placed on the log
    /// while the container was in it.
    ///
    /// The engine replaces the log file for each run, so a cursor opened after `run` ended may
    /// already be on the next run's log. `start` is placed between `run` and a `look` that shows
    /// the container still in that run, so what it reads first is that run's own. A run that
    /// changed in between is the one followed instead, as dockerd follows the run whose log is
    /// current when it opens it, and is looked at again, `attempts` times at most. A container
    /// with no live process, or whose runs keep changing, is not followed: the run is nil, and
    /// the cursor is what is there.
    public static func startFollowing<Cursor>(
        _ run: ContainerSnapshot?, look: () async throws -> ContainerSnapshot?, attempts: Int = 3,
        start: () throws -> Cursor
    ) async throws -> (run: ContainerSnapshot?, cursor: Cursor) {
        var run = run
        for _ in 0..<attempts {
            guard let current = run, current.hasLiveProcess else { break }
            let cursor = try start()
            run = try await look()
            if let after = run, after.isInRun(of: current) { return (current, cursor) }
        }
        return (nil, try start())
    }
}
