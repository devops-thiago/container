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

/// What the engine keeps on disk, per container, so that its restart policy can be applied
/// the same way after the engine itself restarts.
public struct RestartRecord: Codable, Sendable, Equatable {
    /// Whether the last stop was a person's (`container stop`, or a kill of the container's
    /// process), as opposed to the engine shutting down or the process ending by itself.
    /// `unless-stopped` stays down at the next engine start when this is set; `always`
    /// does not look at it there. Set before the stop is sent, so an exit that is reported
    /// while the stop is still in flight already sees it. Cleared by the next start.
    public var stoppedByUser: Bool
    /// Whether the container has ever been started. One that was only created is not started
    /// at engine start, whatever its policy says.
    public var hasBeenStarted: Bool
    /// How many times the engine has started the container again under its policy since it
    /// was last started by hand. `on-failure:N` gives up when this reaches N.
    public var restartCount: Int

    public init(stoppedByUser: Bool = false, hasBeenStarted: Bool = false, restartCount: Int = 0) {
        self.stoppedByUser = stoppedByUser
        self.hasBeenStarted = hasBeenStarted
        self.restartCount = restartCount
    }

    /// The record for a container created before the engine kept one.
    ///
    /// Such a container has a recorded exit if it has run: its process ending, by itself or
    /// because it was stopped, is normally reported with a code. Whether a person stopped it is not known, and the answer
    /// taken is the one that brings an `unless-stopped` container back: before this record
    /// existed the app started those at engine start, so not doing it once would be the
    /// surprise. An `always` container starts either way.
    public static func legacy(hasExitRecord: Bool) -> RestartRecord {
        RestartRecord(stoppedByUser: false, hasBeenStarted: hasExitRecord, restartCount: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case stoppedByUser
        case hasBeenStarted
        case restartCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stoppedByUser = try container.decodeIfPresent(Bool.self, forKey: .stoppedByUser) ?? false
        hasBeenStarted = try container.decodeIfPresent(Bool.self, forKey: .hasBeenStarted) ?? false
        restartCount = try container.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0
    }
}
