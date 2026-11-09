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

/// One node container and the cluster it belongs to, as its labels and name place it.
public struct ClusterNodeMember: Sendable {
    public let clusterName: String
    public let snapshot: ContainerSnapshot

    public init(clusterName: String, snapshot: ContainerSnapshot) {
        self.clusterName = clusterName
        self.snapshot = snapshot
    }
}

/// Groups node containers into clusters from the containers alone. The cluster library's
/// container-derived operations and the clusters service's adoption of record-less clusters
/// both group through here, so they agree on which nodes make up which cluster.
public enum ClusterNodeGroups {
    /// The roles in a node's role label, which joins them with commas.
    public static func roles(of snapshot: ContainerSnapshot) -> [String] {
        snapshot.configuration.labels[ResourceLabelKeys.role, default: ""]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every snapshot with the cluster it belongs to: each control plane followed by its
    /// workers, control planes by ID, then the workers no control plane claimed.
    public static func members(of snapshots: [ContainerSnapshot]) -> [ClusterNodeMember] {
        var controlPlanes: [ContainerSnapshot] = []
        var workers: [ContainerSnapshot] = []
        for snapshot in snapshots {
            if roles(of: snapshot).contains(ClusterConfiguration.controlPlaneRole) {
                controlPlanes.append(snapshot)
            } else {
                workers.append(snapshot)
            }
        }

        let clusterNames = controlPlanes.map { controlPlane in
            explicitClusterName(for: controlPlane) ?? controlPlane.configuration.id
        }
        var members: [ClusterNodeMember] = []
        var assignedWorkerIDs = Set<String>()

        for cp in controlPlanes.sorted(by: { $0.configuration.id < $1.configuration.id }) {
            let clusterName = explicitClusterName(for: cp) ?? cp.configuration.id
            members.append(ClusterNodeMember(clusterName: clusterName, snapshot: cp))
            let cpWorkers =
                workers
                .filter { worker in
                    guard !assignedWorkerIDs.contains(worker.configuration.id) else { return false }
                    if let explicit = explicitClusterName(for: worker) {
                        return explicit == clusterName
                    }
                    // Compatibility for clusters created before the cluster label existed.
                    // Longest-prefix ownership prevents `foo` from also claiming a worker
                    // belonging to a nested cluster named `foo-worker-1`.
                    return legacyClusterName(for: worker, candidates: clusterNames) == clusterName
                }
                .sorted { $0.configuration.id < $1.configuration.id }
            for worker in cpWorkers {
                members.append(ClusterNodeMember(clusterName: clusterName, snapshot: worker))
                assignedWorkerIDs.insert(worker.configuration.id)
            }
        }

        for worker
            in workers
            .filter({ !assignedWorkerIDs.contains($0.configuration.id) })
            .sorted(by: { $0.configuration.id < $1.configuration.id })
        {
            let clusterName =
                explicitClusterName(for: worker)
                ?? legacyClusterName(for: worker, candidates: clusterNames)
                ?? clusterNameDerivedFromWorkerID(worker.configuration.id)
            members.append(ClusterNodeMember(clusterName: clusterName, snapshot: worker))
        }

        return members
    }

    private static func explicitClusterName(for snapshot: ContainerSnapshot) -> String? {
        guard let value = snapshot.configuration.labels[ResourceLabelKeys.cluster], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func legacyClusterName(
        for worker: ContainerSnapshot,
        candidates: [String]
    ) -> String? {
        candidates
            .filter { worker.configuration.id.hasPrefix(ClusterConfiguration.workerNamePrefix(cluster: $0)) }
            .max { lhs, rhs in
                lhs.count == rhs.count ? lhs > rhs : lhs.count < rhs.count
            }
    }

    private static func clusterNameDerivedFromWorkerID(_ id: String) -> String {
        id.components(separatedBy: "-worker-").dropLast().joined(separator: "-worker-")
    }
}
