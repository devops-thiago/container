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

    /// No filters applied. Will return all containers.
    public static let all = ContainerListFilters()

    public init(
        ids: [String] = [],
        status: RuntimeStatus? = nil,
        labels: [String: String] = [:]
    ) {
        self.ids = ids
        self.status = status
        self.labels = labels
    }
}

extension ContainerListFilters {
    public func withoutMachines() -> ContainerListFilters {
        let labels = self.labels.merging([ResourceLabelKeys.plugin: Self.exclude("machine")]) { _, new in new }
        return ContainerListFilters(ids: self.ids, status: self.status, labels: labels)
    }

    /// The plugins whose containers are infrastructure the engine manages for the user —
    /// a machine's VM, a Kubernetes node — and which generic container operations must
    /// neither list nor touch. One list, so every screen and every prune excludes the same
    /// things; the plugin's own screen manages them through its own path.
    public static let infrastructurePlugins: [String] = ["machine", "k8s"]

    /// Whether a container carrying `labels` is engine-managed infrastructure.
    public static func isInfrastructure(labels: [String: String]) -> Bool {
        guard let plugin = labels[ResourceLabelKeys.plugin] else { return false }
        return infrastructurePlugins.contains(plugin)
    }

    /// Exclude every infrastructure plugin's containers, not only machines.
    public func withoutInfrastructure() -> ContainerListFilters {
        let pattern = "^(?!(" + Self.infrastructurePlugins.joined(separator: "|") + ")$)"
        let labels = self.labels.merging([ResourceLabelKeys.plugin: pattern]) { _, new in new }
        return ContainerListFilters(ids: self.ids, status: self.status, labels: labels)
    }
}
