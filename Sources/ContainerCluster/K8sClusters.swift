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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage
import TerminalProgress
import Yams

/// Cluster operations as a library, for embedders.
///
/// The commands in `Commands/` are CLI wrappers: they bootstrap the process-global logging
/// system (which traps if done twice), draw a terminal progress bar, and print their result.
/// None of that survives being called twice from a long-lived process, so an embedder needs
/// the operations themselves — same steps, parameterized logger and progress, results
/// returned instead of printed. The commands call through here so the two cannot drift.
public enum K8sClusters {
    public static let maximumWorkers = 64
    public static let defaultName = K8sHelper.defaultName
    public static let defaultNodeImage = K8sHelper.nodeImage

    /// One cluster node, described with the fields `k8s list` prints.
    public struct Node: Sendable, Equatable {
        public struct PortMapping: Sendable, Equatable {
            public let hostPort: Int
            public let containerPort: Int
        }

        public let clusterName: String
        /// The node's container ID; for a single-node cluster this equals the cluster name.
        public let id: String
        /// Opaque identity of this exact creation of the node container.
        public let incarnation: String
        public let role: String
        /// The underlying container status, e.g. "running" or "stopped".
        public let state: String
        public let cpus: Int
        public let memoryBytes: UInt64
        public let addresses: [String]
        public let ports: [PortMapping]
        public let creationDate: Date
    }

    public static func nameValid(_ name: String) -> Bool {
        ManagedContainer.nameValid(name)
    }

    public static func list() async throws -> [Node] {
        let snapshots = try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: K8sHelper.pluginName])
        )
        return K8sHelper.buildK8sRows(from: snapshots).map { row in
            Node(
                clusterName: row.clusterName,
                id: row.snapshot.configuration.id,
                incarnation: row.snapshot.incarnation,
                role: row.snapshot.configuration.labels[ResourceLabelKeys.role] ?? "",
                state: row.snapshot.status.rawValue,
                cpus: row.snapshot.configuration.resources.cpus,
                memoryBytes: row.snapshot.configuration.resources.memoryInBytes,
                addresses: row.snapshot.networks.map { $0.ipv4Address.address.description },
                ports: row.snapshot.configuration.publishedPorts.map {
                    Node.PortMapping(hostPort: Int($0.hostPort), containerPort: Int($0.containerPort))
                },
                creationDate: row.snapshot.configuration.creationDate
            )
        }
    }

    /// What a create finished with, beyond the cluster itself.
    public struct CreateResult: Sendable {
        /// Whether the kubeconfig was merged. False means the cluster is up and usable but
        /// nothing was written, so the caller has to say how to get one — advice only it can
        /// phrase, since a command points at another command and an app points at a button.
        public let kubeconfigWritten: Bool
    }

    /// Create and start one control plane plus `workers` worker nodes.
    ///
    /// `workers` defaults to zero for source and CLI compatibility with the historical
    /// single-node cluster. In that form the control plane remains schedulable.
    @discardableResult
    public static func create(
        name: String = K8sClusters.defaultName,
        nodeImage: String = K8sClusters.defaultNodeImage,
        cpus: Int64? = nil,
        memory: String? = nil,
        workers: Int = 0,
        autoRemove: Bool = false,
        registry: Flags.Registry = Flags.Registry(scheme: "https"),
        imageFetch: Flags.ImageFetch = Flags.ImageFetch(maxConcurrentDownloads: 3),
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws -> CreateResult {
        guard nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "cluster name \(name) is not a valid container ID")
        }
        guard (0...maximumWorkers).contains(workers) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "worker count must be between 0 and \(maximumWorkers)")
        }

        let workerNames = workers == 0 ? [] : (1...workers).map { "\(name)-worker-\($0)" }
        guard workerNames.allSatisfy({ nameValid($0) }) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "cluster name \(name) is too long to form worker container IDs")
        }

        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
        let fqdn = K8sHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)
        let controlPlane = try LinuxNodeProvisioner(
            clusterName: name,
            roles: [StandardRoles.controlPlane],
            nodeImage: nodeImage,
            cpus: cpus,
            memory: memory,
            registryScheme: registry.scheme,
            maxConcurrentDownloads: imageFetch.maxConcurrentDownloads,
            remove: autoRemove,
            fqdn: fqdn,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progressUpdate)
        let workerNodes = try workerNames.map { workerName in
            WorkerNode(
                name: workerName,
                provisioner: try LinuxNodeProvisioner(
                    clusterName: name,
                    roles: [StandardRoles.worker],
                    nodeImage: nodeImage,
                    cpus: cpus,
                    memory: memory,
                    registryScheme: registry.scheme,
                    maxConcurrentDownloads: imageFetch.maxConcurrentDownloads,
                    remove: autoRemove,
                    containerSystemConfig: containerSystemConfig,
                    progressUpdate: progressUpdate))
        }

        let client = ContainerClient()
        try await provisionCluster(
            name: name,
            controlPlane: controlPlane,
            workers: workerNodes,
            initializeControlPlane: { controlPlaneName, vmIP, hasWorkers in
                var sans = ["127.0.0.1"]
                if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

                await progressUpdate([.setDescription("Running kubeadm init")])
                try await K8sHelper.prepareNode(
                    nodeID: controlPlaneName, client: client, log: log)
                try await K8sHelper.bootstrapControlPlane(
                    nodeID: controlPlaneName,
                    apiServerSANs: sans,
                    advertiseAddress: vmIP,
                    schedulable: !hasWorkers,
                    client: client,
                    log: log)

                guard hasWorkers else { return nil }
                let join = try await K8sHelper.createJoinToken(
                    nodeID: controlPlaneName, client: client)
                return JoinCredentials(token: join.token, caCertHash: join.caCertHash)
            },
            finalizeCluster: {
                await progressUpdate([.setDescription("Waiting for cluster to be ready")])
                try await K8sHelper.waitForReady(
                    containerId: name, client: client, log: log)
            },
            log: log,
            progressUpdate: progressUpdate)

        await progressUpdate([.setDescription("Writing kubeconfig")])
        do {
            let rawConfig = try await K8sHelper.fetchConfig(
                containerId: name, client: client, log: log)
            let kubeConfig = try await K8sHelper.transformConfig(
                rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(
                kubeConfig, containerId: name, setCurrentContext: true, log: log)
        } catch {
            // Not fatal: the cluster is up, and only the kubeconfig is missing. Reported
            // rather than thrown so the caller keeps the cluster and can say how to recover.
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
            return CreateResult(kubeconfigWritten: false)
        }
        return CreateResult(kubeconfigWritten: true)
    }

    /// The cluster's kubeconfig as YAML, rewritten to reach the API server from this host —
    /// what `k8s write-config` writes, returned instead so an embedder can put it where the
    /// user asks.
    public static func kubeconfigYAML(name: String = K8sClusters.defaultName, log: Logger) async throws -> String {
        let client = ContainerClient()
        let fqdn = await K8sHelper.detectFQDN(name: name)
        let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
        let config = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
        return try YAMLEncoder().encode(config)
    }

    /// Start every stopped node in a cluster, control plane first, then wait for the whole
    /// cluster to answer again.
    public static func start(name: String = K8sClusters.defaultName, log: Logger) async throws {
        let client = ContainerClient()
        let controlPlane = try await client.get(id: name)
        guard controlPlane.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }

        let listed = try await client.list(
            filters: ContainerListFilters(
                labels: [ResourceLabelKeys.plugin: K8sHelper.pluginName]))
        let workers = K8sHelper.buildK8sRows(from: listed)
            .filter { $0.clusterName == name && $0.snapshot.id != name }
            .map(\.snapshot)
            .sorted { $0.id < $1.id }

        try Task.checkCancellation()
        try await startNodeIfNeeded(controlPlane, client: client, log: log)
        // Idempotent, and it heals clusters created before the loopback pin existed: their
        // admin kubeconfigs still name whatever address the node had at kubeadm init.
        try Task.checkCancellation()
        try await K8sHelper.pinAdminKubeconfigsToLoopback(nodeID: name, client: client)
        for worker in workers {
            try Task.checkCancellation()
            try await startNodeIfNeeded(worker, client: client, log: log)
        }
        try Task.checkCancellation()
        try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

        do {
            let fqdn = await K8sHelper.detectFQDN(name: name)
            let rawConfig = try await K8sHelper.fetchConfig(
                containerId: name, client: client, log: log)
            let config = try await K8sHelper.transformConfig(
                rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(config, containerId: name, log: log)
        } catch {
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
        }
    }

    private static func startNodeIfNeeded(
        _ node: ContainerSnapshot,
        client: ContainerClient,
        log: Logger
    ) async throws {
        guard node.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            throw ContainerizationError(.invalidArgument, message: "\(node.id) is not a k8s node")
        }
        guard node.status != .running else { return }
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: node.id, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()
        try await K8sHelper.waitForNodeBooted(containerId: node.id, client: client, log: log)
    }

    /// Stop and remove a cluster, and drop its context from the default kubeconfig.
    public static func delete(
        name: String = K8sClusters.defaultName,
        expectedControlPlaneIncarnation: String? = nil,
        log: Logger
    ) async throws {
        try await delete(
            name: name,
            expectedControlPlaneIncarnation: expectedControlPlaneIncarnation,
            containers: ContainerClient(),
            log: log)
    }

    /// The labels a container must carry to be treated as a cluster node here.
    static var nodeLabels: [String: String] { [ResourceLabelKeys.plugin: K8sHelper.pluginName] }

    /// The delete, with its container access injectable.
    ///
    /// Every node mutation carries both plugin ownership and the exact incarnation observed
    /// before any stop. Workers are removed before the control plane. A lookup/list failure
    /// performs no mutation, and kubeconfig is kept until the whole guarded delete succeeds.
    static func delete(
        name: String,
        expectedControlPlaneIncarnation: String? = nil,
        containers: any K8sClusterContainers,
        log: Logger
    ) async throws {
        let listed = try await containers.listNodes()
        let clusterNodes = K8sHelper.buildK8sRows(from: listed)
            .filter { $0.clusterName == name }
            .map(\.snapshot)
        let controlPlane: ContainerSnapshot?
        if let observed = clusterNodes.first(where: { $0.id == name }) {
            controlPlane = observed
        } else {
            // No plugin-owned control plane appeared in the atomic list. Distinguish a
            // definite absence from an ordinary container using the ID. Surviving workers
            // still need cleanup after an interrupted or asymmetric earlier deletion.
            do {
                controlPlane = try await containers.get(id: name)
            } catch let error as ContainerizationError where error.code == .notFound {
                controlPlane = nil
                if expectedControlPlaneIncarnation != nil {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "\(name) is no longer the cluster incarnation this operation observed")
                }
                if clusterNodes.isEmpty {
                    log.debug("cluster container not found, skipping delete", metadata: ["name": "\(name)"])
                    try K8sHelper.removeConfig(containerId: name, log: log)
                    return
                }
                log.debug(
                    "control plane not found; deleting surviving cluster workers",
                    metadata: ["name": "\(name)"])
            }
        }
        if let controlPlane {
            guard controlPlane.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
                throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
            }
            if let expectedControlPlaneIncarnation,
                controlPlane.incarnation != expectedControlPlaneIncarnation
            {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "\(name) is not the cluster incarnation this operation observed")
            }
        }

        var nodes = clusterNodes.filter { $0.id != name }
        nodes.sort { $0.id < $1.id }
        if let controlPlane { nodes.append(controlPlane) }

        for node in nodes {
            guard node.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
                throw ContainerizationError(
                    .invalidArgument, message: "\(node.id) is not a k8s cluster node")
            }
            if let owner = node.configuration.labels[ResourceLabelKeys.cluster], owner != name {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "\(node.id) belongs to k8s cluster \(owner), not \(name)")
            }
            var requiredLabels = nodeLabels
            if node.configuration.labels[ResourceLabelKeys.cluster] != nil {
                requiredLabels[ResourceLabelKeys.cluster] = name
            }
            do {
                do {
                    try await containers.stop(
                        id: node.id,
                        requiredLabels: requiredLabels,
                        expectedIncarnation: node.incarnation)
                } catch let error as ContainerizationError where error.code == .invalidArgument {
                    throw error
                } catch {
                    log.debug(
                        "cluster node stop before delete failed; deleting anyway",
                        metadata: ["name": "\(node.id)", "error": "\(error)"])
                }
                try await containers.delete(
                    id: node.id,
                    requiredLabels: requiredLabels,
                    expectedIncarnation: node.incarnation)
            } catch let error as ContainerizationError where error.code == .notFound {
                log.debug("cluster node not found, skipping delete", metadata: ["name": "\(node.id)"])
            }
        }

        try K8sHelper.removeConfig(containerId: name, log: log)
    }
}

/// What `K8sClusters.delete` needs from the engine, so a test can stand in for it.
protocol K8sClusterContainers: Sendable {
    func get(id: String) async throws -> ContainerSnapshot
    func listNodes() async throws -> [ContainerSnapshot]
    func stop(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws
    func delete(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws
}

extension ContainerClient: K8sClusterContainers {
    func listNodes() async throws -> [ContainerSnapshot] {
        try await list(
            filters: ContainerListFilters(
                labels: [ResourceLabelKeys.plugin: K8sHelper.pluginName]))
    }

    func stop(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws {
        try await stop(
            id: id,
            opts: .default,
            requiredLabels: requiredLabels,
            expectedIncarnation: expectedIncarnation)
    }

    func delete(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws {
        try await delete(
            id: id,
            force: false,
            requiredLabels: requiredLabels,
            expectedIncarnation: expectedIncarnation)
    }
}
