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

/// One change to a container, as the API server made it: written where the change is made, in
/// the order the changes were made, never worked out afterwards from two listings.
///
/// Carries what a client filters on, the container's labels, image and name as they were at
/// the change, so that it needs no lookup, and none could find a container already gone.
public struct ContainerEvent: Codable, Sendable, Equatable {
    /// What happened. A string underneath, so that a client reads an action from a newer
    /// server as an action it does not know rather than failing on it.
    public struct Action: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var description: String { rawValue }

        /// The container was made.
        public static let create = Action(rawValue: "create")
        /// Its process is running: a start by hand, or one the engine made for a restart policy.
        public static let start = Action(rawValue: "start")
        /// The OOM killer killed one of its processes, as Docker's `oom` says; reported when
        /// the run ends, before its `die`.
        public static let oom = Action(rawValue: "oom")
        /// Its process ended, however it ended; `exitCode` says how when it is known.
        public static let die = Action(rawValue: "die")
        /// The container was removed.
        public static let destroy = Action(rawValue: "destroy")
        /// Its name changed; `attributes["oldName"]` is the one it had.
        public static let rename = Action(rawValue: "rename")
        /// Its health status changed; `health` is the new one.
        public static let healthStatus = Action(rawValue: "health_status")
        /// A signal was sent to its process; `attributes["signal"]` names it.
        public static let kill = Action(rawValue: "kill")
        /// A stop asked of it is done.
        public static let stop = Action(rawValue: "stop")
    }

    /// Counts the events of one API server process from 1, with no gaps. A client that
    /// reconnects asks for the events after the last one it saw. Only meaningful next to the
    /// process nonce of the server that numbered it.
    public var sequence: UInt64
    /// When the change was made, in nanoseconds since 1970.
    public var timeNano: Int64
    /// The container's ID.
    public var id: String
    /// This creation of the container: a container made again under the same ID has another.
    public var incarnation: String
    public var action: Action
    /// The container's name: its name label when the server keeps one, otherwise its ID.
    public var name: String
    /// The image reference the container was made from.
    public var image: String
    /// The container's labels at the change.
    public var labels: [String: String]
    /// How the process ended, on `die`, when that is known.
    public var exitCode: Int32?
    /// The new health status, on `health_status`.
    public var health: HealthStatus?
    /// What else the action says: `signal` on `kill`, `oldName` on `rename`.
    public var attributes: [String: String]

    public init(
        sequence: UInt64, timeNano: Int64, id: String, incarnation: String, action: Action, name: String, image: String,
        labels: [String: String], exitCode: Int32? = nil, health: HealthStatus? = nil, attributes: [String: String] = [:]
    ) {
        self.sequence = sequence
        self.timeNano = timeNano
        self.id = id
        self.incarnation = incarnation
        self.action = action
        self.name = name
        self.image = image
        self.labels = labels
        self.exitCode = exitCode
        self.health = health
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case sequence, timeNano, id, incarnation, action, name, image, labels, exitCode, health, attributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        timeNano = try container.decode(Int64.self, forKey: .timeNano)
        id = try container.decode(String.self, forKey: .id)
        incarnation = try container.decodeIfPresent(String.self, forKey: .incarnation) ?? ""
        action = try container.decode(Action.self, forKey: .action)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        // A status this client does not know is left out rather than failing the event.
        health = try? container.decodeIfPresent(HealthStatus.self, forKey: .health)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
    }

    /// When the change was made.
    public var time: Date {
        Date(timeIntervalSince1970: Double(timeNano) / 1_000_000_000)
    }
}

/// Where a client of the event stream is: the server process it was reading, and the last
/// event of that process it saw. The server replays what came after it, when it still can.
public struct ContainerEventCursor: Codable, Sendable, Hashable {
    public var processNonce: String
    public var sequence: UInt64

    public init(processNonce: String, sequence: UInt64) {
        self.processNonce = processNonce
        self.sequence = sequence
    }
}
