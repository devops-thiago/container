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

/// Filters for listing containers.
public struct ContainerListFilters: Sendable, Codable {
    public static func exclude(_ str: String) -> String {
        "^(?!\(str)$)"
    }

    /// An additional label condition. A nil pattern requires the key to exist, even
    /// when its value is empty. A pattern keeps the legacy missing-as-empty semantics.
    public struct LabelCondition: Sendable, Codable, Equatable {
        public var key: String
        public var pattern: String?

        public init(key: String, pattern: String? = nil) {
            self.key = key
            self.pattern = pattern
        }
    }

    /// Filter by container IDs. If non-empty, only containers with matching IDs are returned.
    public var ids: [String]
    /// Filter by container status.
    public var status: RuntimeStatus?
    /// Filter by labels. All specified labels must match. Values are treated as regular expressions
    /// matched against the container's label value. If a container does not have the specified key,
    /// the value is treated as an empty string. This means a positive pattern (e.g. ``^b$``) will
    /// exclude containers without the label, while a negation pattern (e.g. ``^(?!b$)``) will
    /// include them.
    public var labels: [String: String]
    /// Filter by container ID with a regular expression. Unlike ``ids`` it is searched for in
    /// the ID, so ``web`` matches every container whose ID mentions it and ``^web$`` one.
    public var name: String?
    /// Additional label conditions, all ANDed with ``labels``. Optional on the wire so
    /// requests from clients predating key-presence and repeated conditions still decode.
    public var labelConditions: [LabelCondition]?

    /// No filters applied. Will return all containers.
    public static let all = ContainerListFilters()

    public init(
        ids: [String] = [],
        status: RuntimeStatus? = nil,
        labels: [String: String] = [:],
        name: String? = nil,
        labelConditions: [LabelCondition]? = nil
    ) {
        self.ids = ids
        self.status = status
        self.labels = labels
        self.name = name
        self.labelConditions = labelConditions
    }
}

extension ContainerListFilters {
    public func withoutMachines() -> ContainerListFilters {
        var filters = self
        filters.addPluginCondition(Self.exclude("machine"))
        return filters
    }

    /// Whether a container carrying `labels` is engine/plugin-managed infrastructure.
    ///
    /// The plugin metadata is the ownership boundary. Enumerating today's plugins here made
    /// every new shipped plugin briefly visible to generic delete/prune until the app learned
    /// its name. A user can hide their own container by setting this reserved key, but cannot
    /// gain mutation authority over another container; exact authority is its incarnation.
    public static func isInfrastructure(labels: [String: String]) -> Bool {
        guard let plugin = labels[ResourceLabelKeys.plugin] else { return false }
        return !plugin.isEmpty
    }

    /// Exclude every plugin-owned container, including plugins added after this client ships.
    public func withoutInfrastructure() -> ContainerListFilters {
        var filters = self
        filters.addPluginCondition("^$")
        return filters
    }
    private mutating func addPluginCondition(_ pattern: String) {
        let key = ResourceLabelKeys.plugin
        if labels[key] == nil {
            labels[key] = pattern
        } else {
            // Preserve the caller's condition; exclusions narrow a request, never replace it.
            labelConditions = (labelConditions ?? []) + [LabelCondition(key: key, pattern: pattern)]
        }
    }

}
