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

    public init(
        configuration: ContainerConfiguration,
        incarnation: String = "",
        status: RuntimeStatus,
        networks: [Attachment],
        startedDate: Date? = nil,
        exitCode: Int32? = nil,
        exitedAt: Date? = nil
    ) {
        self.configuration = configuration
        self.incarnation = incarnation
        self.status = status
        self.networks = networks
        self.startedDate = startedDate
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case incarnation
        case status
        case networks
        case startedDate
        case exitCode
        case exitedAt
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
    }
}
