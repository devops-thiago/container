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
import Foundation
import Logging

/// Rebuilds the records of clusters whose node containers exist but that have no record.
///
/// Engines before 1.7.1 kept no cluster records: a cluster was its node containers. Their
/// clusters survive an update with nodes and no record, so the service rebuilds one from
/// what those nodes carry. Every engine from 1.4 on labelled a node with the plugin
/// (`cluster`, or `k8s` before 1.6.1) and its roles (comma-joined); ours from 1.4.1 on also
/// with the cluster's name, and from 1.5.0 on with the caller's `--label`s. Upstream's
/// workers carry no cluster label and are found by their `<cluster>-worker-<n>` names.
enum RecordlessClusters {
    /// The node image tag every engine from 1.4 to 1.6.1 created clusters with by default,
    /// for a node whose image reference carries no tag.
    static let defaultKubernetesVersion = "v1.35.5"

    /// A configuration for each cluster in `snapshots` that `recorded` does not name and
    /// whose control-plane node is among them. Containers that are not Kubernetes nodes are
    /// ignored. A group that does not make a valid configuration is logged and skipped.
    static func configurations(
        from snapshots: [ContainerSnapshot], recorded: Set<String>, log: Logger
    ) -> [ClusterConfiguration] {
        let nodes = snapshots.filter { ResourcePluginValues.isKubernetes($0.configuration.labels[ResourceLabelKeys.plugin]) }
        var groups: [String: [ContainerSnapshot]] = [:]
        var order: [String] = []
        for member in ClusterNodeGroups.members(of: nodes) where !recorded.contains(member.clusterName) {
            if groups[member.clusterName] == nil { order.append(member.clusterName) }
            groups[member.clusterName, default: []].append(member.snapshot)
        }
        return order.compactMap { name in
            do {
                return try configuration(name: name, nodes: groups[name] ?? [], log: log)
            } catch {
                log.warning("cannot adopt cluster without a record", metadata: ["name": "\(name)", "error": "\(error)"])
                return nil
            }
        }
    }

    /// The configuration of cluster `name` rebuilt from its node containers, or nil when its
    /// control plane is not among them.
    ///
    /// A group with no control plane is left alone: upstream's `cluster list` shows records
    /// only, so it would not show one either, and `cluster delete` removes the surviving
    /// workers from the containers without needing a record. Without its control plane
    /// such a group cannot be started, reached or given a kubeconfig.
    static func configuration(name: String, nodes: [ContainerSnapshot], log: Logger) throws -> ClusterConfiguration? {
        // The control plane's container ID is the cluster's name; `cluster start`, `stop`
        // and `delete` look it up by that name.
        guard
            let controlPlane = nodes.first(where: {
                $0.configuration.id == name && ClusterNodeGroups.roles(of: $0).contains(ClusterConfiguration.controlPlaneRole)
            })
        else {
            log.debug("not adopting cluster nodes without their control plane", metadata: ["name": "\(name)"])
            return nil
        }
        let workers = nodes.filter { $0.configuration.id != name }.sorted { workerOrder($0.configuration.id, $1.configuration.id) }

        // Engines before 1.7.1 labelled a single node `control-plane` only; it is schedulable
        // and carries both roles, as 1.7.1 labels it.
        var controlPlaneRoles = ClusterNodeGroups.roles(of: controlPlane)
        if workers.isEmpty && !controlPlaneRoles.contains(ClusterConfiguration.workerRole) {
            controlPlaneRoles.append(ClusterConfiguration.workerRole)
        }
        var nodeConfigurations = [try NodeConfiguration(name: controlPlane.configuration.id, roles: controlPlaneRoles)]
        for worker in workers {
            let roles = ClusterNodeGroups.roles(of: worker)
            nodeConfigurations.append(
                try NodeConfiguration(name: worker.configuration.id, roles: roles.isEmpty ? [ClusterConfiguration.workerRole] : roles))
        }

        let kubernetesVersion =
            (try? ClusterConfiguration.kubernetesVersion(nodeImage: controlPlane.configuration.image.reference))
            ?? defaultKubernetesVersion

        // The labels a create was given travel on every node beside the reserved ones. One a
        // cluster record could not hold is left out rather than losing the cluster.
        let reserved: Set<String> = [ResourceLabelKeys.plugin, ResourceLabelKeys.cluster, ResourceLabelKeys.role]
        let userLabels = controlPlane.configuration.labels.filter { key, value in
            !reserved.contains(key) && (try? ResourceLabels.validateLabel(key: key, value: value)) != nil
        }

        return try ClusterConfiguration(
            name: name,
            kubernetesVersion: kubernetesVersion,
            // The `--cni` manifest path was never put on a node, so the default (nil, the
            // bundled kindnet) is recorded. A no-CNI cluster's readiness policy lives in its
            // control plane, where `cluster start` still reads it.
            cni: nil,
            fqdn: fqdn(name: name, controlPlane: controlPlane),
            // Auto-remove is kept among the engine's create options, not on the container, so
            // the default (false) is recorded. Once a `--rm` cluster stops and its nodes go,
            // the record is stale, which `create` replaces and `delete` removes.
            remove: false,
            // Engines before 1.7.1 had no shared image store.
            sharedImageStore: false,
            nodes: nodeConfigurations,
            creationDate: controlPlane.configuration.creationDate,
            labels: (try? ResourceLabels(userLabels)) ?? ResourceLabels())
    }

    /// The name earlier engines gave the API server: the cluster name if it is already
    /// qualified, else the name under the DNS domain the engine was configured with when the
    /// control plane was made, which its container keeps.
    static func fqdn(name: String, controlPlane: ContainerSnapshot) -> String? {
        if name.contains(".") { return name }
        guard let domain = controlPlane.configuration.dns?.domain, !domain.isEmpty else { return nil }
        return "\(name).\(domain)"
    }

    /// Workers in index order (`-worker-2` before `-worker-10`), then by name.
    private static func workerOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (workerIndex(lhs), workerIndex(rhs)) {
        case (let l?, let r?) where l != r: return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs < rhs
        }
    }

    private static func workerIndex(_ id: String) -> Int? {
        guard let range = id.range(of: "-worker-", options: .backwards) else { return nil }
        return Int(id[range.upperBound...])
    }
}
