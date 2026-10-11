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
        health: ContainerHealth? = nil
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
    }
}
