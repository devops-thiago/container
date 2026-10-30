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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging

protocol ClusterStartupOperations: Sendable {
    func controlPlane(name: String) async throws -> ContainerSnapshot
    func nodes() async throws -> [ContainerSnapshot]
    func authorize(_ nodes: [ContainerSnapshot], name: String, adoptLegacy: Bool) async throws
    func start(_ node: ContainerSnapshot) async throws
    func pinKubeconfig(name: String) async throws
    func storedPolicy(name: String) async throws -> ClusterReadinessPolicy?
    func storePolicy(_ policy: ClusterReadinessPolicy, name: String) async throws
    func waitForReady(name: String) async throws
    func waitForRegistered(name: String, nodes: [String]) async throws
    func writeKubeconfig(name: String) async throws
}

extension K8sClusters {
    static func start(
        name: String, adoptLegacy: Bool, readiness: ClusterReadinessPolicy?,
        operations: any ClusterStartupOperations, log: Logger
    ) async throws {
        let controlPlane = try await operations.controlPlane(name: name)
        guard ClusterHelper.ownsNode(controlPlane.configuration.labels) else {
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a cluster")
        }
        let workers = ClusterHelper.buildClusterRows(from: try await operations.nodes())
            .filter { $0.clusterName == name && $0.snapshot.id != name }
            .map(\.snapshot).sorted { $0.id < $1.id }

        // Preserve the all-node adoption preflight before starting anything or reading
        // guest metadata. Choosing a readiness policy is not permission to adopt nodes.
        try await operations.authorize([controlPlane] + workers, name: name, adoptLegacy: adoptLegacy)
        try Task.checkCancellation()
        try await operations.start(controlPlane)
        try Task.checkCancellation()
        try await operations.pinKubeconfig(name: name)
        let policy: ClusterReadinessPolicy
        if let readiness {
            // Persist an explicit choice before checking health. A broken CNI must not
            // silently fall back to the previous, weaker policy on the next start.
            try await operations.storePolicy(readiness, name: name)
            policy = readiness
        } else {
            policy = try await operations.storedPolicy(name: name) ?? .ready
        }
        for worker in workers {
            try Task.checkCancellation()
            try await operations.start(worker)
        }
        try Task.checkCancellation()
        switch policy {
        case .ready: try await operations.waitForReady(name: name)
        case .registered:
            try await operations.waitForRegistered(name: name, nodes: [controlPlane.id] + workers.map(\.id))
        }
        try Task.checkCancellation()
        do {
            try await operations.writeKubeconfig(name: name)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
        }
    }
}

struct LiveClusterStartup: ClusterStartupOperations {
    let client: ContainerClient
    let log: Logger

    func controlPlane(name: String) async throws -> ContainerSnapshot { try await client.get(id: name) }
    func nodes() async throws -> [ContainerSnapshot] { try await client.list(filters: ClusterHelper.nodeListFilters) }

    func authorize(_ nodes: [ContainerSnapshot], name: String, adoptLegacy: Bool) async throws {
        try await client.prepareWritableSysfs(
            nodes, role: .kubernetes, adoptLegacy: adoptLegacy,
            adoptionCommand: "container cluster start --name \(name) --adopt-legacy")
    }

    func start(_ node: ContainerSnapshot) async throws {
        guard ClusterHelper.ownsNode(node.configuration.labels) else {
            throw ContainerizationError(.invalidArgument, message: "\(node.id) is not a cluster node")
        }
        guard node.status != .running else { return }
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: node.id, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()
        try await ClusterHelper.waitForNodeBooted(containerId: node.id, client: client, log: log)
    }

    func pinKubeconfig(name: String) async throws {
        try await ClusterHelper.pinAdminKubeconfigsToLoopback(nodeID: name, client: client)
    }
    func storedPolicy(name: String) async throws -> ClusterReadinessPolicy? {
        try await ClusterHelper.readReadinessPolicy(name: name, client: client)
    }
    func storePolicy(_ policy: ClusterReadinessPolicy, name: String) async throws {
        try await ClusterHelper.writeReadinessPolicy(policy, name: name, client: client)
    }
    func waitForReady(name: String) async throws {
        try await ClusterHelper.waitForReady(containerId: name, client: client, log: log)
    }
    func waitForRegistered(name: String, nodes: [String]) async throws {
        try await ClusterHelper.waitForAPIServer(containerId: name, client: client, log: log)
        try await ClusterHelper.waitForRegisteredNodes(containerId: name, nodes: nodes, log: log) { arguments, deadline in
            try await ClusterHelper.runProbe(client: client, containerId: name, arguments: arguments, deadline: deadline)
        }
    }
    func writeKubeconfig(name: String) async throws {
        let fqdn = await ClusterHelper.detectFQDN(name: name)
        let raw = try await ClusterHelper.fetchConfig(containerId: name, client: client, log: log)
        let config = try await ClusterHelper.transformConfig(raw, containerId: name, fqdn: fqdn, client: client)
        try ClusterHelper.mergeConfig(config, containerId: name, log: log)
    }
}
