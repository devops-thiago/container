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
import ContainerClusterServiceClient
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
    public static let defaultName = ClusterHelper.defaultName
    public static let defaultNodeImage = ClusterHelper.nodeImage

    /// One cluster node, described with the fields `cluster list` prints.
    public struct Node: Sendable, Equatable {
        public struct PortMapping: Sendable, Equatable {
            public let hostPort: Int
            public let containerPort: Int
        }

        public let clusterName: String
        /// The node's container ID; the control plane's equals the cluster name.
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

    /// A cluster's name is its control plane's container ID and hostname, and Kubernetes takes
    /// a node's hostname as its name, so it stays within a DNS label.
    public static func nameValid(_ name: String) -> Bool {
        name.utf8.count <= ContainerHostname.maxLabelLength && ManagedContainer.nameValid(name)
    }

    public static func list() async throws -> [Node] {
        let snapshots = try await ContainerClient().list(
            filters: ClusterHelper.nodeListFilters
        )
        return ClusterHelper.buildClusterRows(from: snapshots).map { row in
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

    /// The size of a group of identical worker nodes, as `cluster create --workers
    /// count=<n>,cpus=<n>,memory=<size>` describes one. A size left out takes the single-node
    /// default (1/4 of host CPUs and memory, minimum 2 CPUs and 2g).
    public struct WorkerGroup: Sendable, Equatable {
        public var count: Int
        public var cpus: Int64?
        public var memory: String?

        public init(count: Int, cpus: Int64? = nil, memory: String? = nil) {
            self.count = count
            self.cpus = cpus
            self.memory = memory
        }
    }

    /// Create and start one control plane plus `workers` worker nodes and the worker groups
    /// in `workerGroups`, and record the cluster with the cluster service.
    ///
    /// `workers` defaults to zero for source and CLI compatibility with the historical
    /// single-node cluster. In that form the control plane remains schedulable. Workers
    /// counted by `workers` take the control plane's `cpus` and `memory`; each group
    /// sizes its own. Workers are numbered across both, `workers` first.
    @discardableResult
    public static func create(
        name: String = K8sClusters.defaultName,
        labels: [String: String] = [:],
        nodeImage: String = K8sClusters.defaultNodeImage,
        cpus: Int64? = nil,
        memory: String? = nil,
        workers: Int = 0,
        workerGroups: [WorkerGroup] = [],
        cniManifestPath: String? = nil,
        autoRemove: Bool = false,
        sharedImageStore: Bool = false,
        registry: Flags.Registry = Flags.Registry(scheme: "https"),
        imageFetch: Flags.ImageFetch = Flags.ImageFetch(maxConcurrentDownloads: 3),
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws -> CreateResult {
        guard nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "cluster name \(name) is not a valid container ID")
        }
        let workerSizes = try workerSizes(workers: workers, cpus: cpus, memory: memory, groups: workerGroups)
        // "NONE" installs no CNI: nodes stay NotReady until the caller installs one, so the
        // create waits for the API server and for workers to register, not for readiness.
        let readinessPolicy = ClusterReadinessPolicy.forCreation(cniManifestPath: cniManifestPath)
        let skipCNI = readinessPolicy == .registered
        if let cniManifestPath, !skipCNI {
            guard FileManager.default.fileExists(atPath: cniManifestPath) else {
                throw ContainerizationError(.invalidArgument, message: "CNI manifest not found at \(cniManifestPath)")
            }
        }

        let workerNames = workerSizes.indices.map { ClusterHelper.workerName(cluster: name, index: $0 + 1) }
        guard workerNames.allSatisfy({ nameValid($0) }) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "cluster name \(name) is too long to form worker container IDs")
        }

        let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
        let fqdn = ClusterHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)
        // Validates the node image's version and the node list; fails before any node VM.
        let made = try ClusterConfiguration.make(
            name: name,
            nodeImage: nodeImage,
            remove: autoRemove,
            sharedImageStore: sharedImageStore,
            workers: UInt(workerSizes.count),
            cni: cniManifestPath,
            fqdn: fqdn)
        let configuration = try ClusterConfiguration(
            name: made.name,
            kubernetesVersion: made.kubernetesVersion,
            cni: made.cni,
            fqdn: made.fqdn,
            remove: made.remove,
            sharedImageStore: made.sharedImageStore,
            nodes: made.nodes,
            creationDate: made.creationDate,
            labels: try ResourceLabels(labels))

        let controlPlane = try LinuxNodeProvisioner(
            name: name,
            clusterName: name,
            labels: labels,
            roles: workerSizes.isEmpty ? [StandardRoles.controlPlane, StandardRoles.worker] : [StandardRoles.controlPlane],
            nodeImage: nodeImage,
            cpus: cpus,
            memory: memory,
            registryScheme: registry.scheme,
            maxConcurrentDownloads: imageFetch.maxConcurrentDownloads,
            remove: autoRemove,
            containerSystemConfig: containerSystemConfig,
            fqdn: fqdn,
            sharedImageStore: sharedImageStore,
            progressUpdate: progressUpdate)
        let workerNodes = try zip(workerNames, workerSizes).map { workerName, size in
            WorkerNode(
                name: workerName,
                provisioner: try LinuxNodeProvisioner(
                    name: workerName,
                    clusterName: name,
                    labels: labels,
                    roles: [StandardRoles.worker],
                    nodeImage: nodeImage,
                    cpus: size.cpus,
                    memory: size.memory,
                    registryScheme: registry.scheme,
                    maxConcurrentDownloads: imageFetch.maxConcurrentDownloads,
                    remove: autoRemove,
                    containerSystemConfig: containerSystemConfig,
                    sharedImageStore: sharedImageStore,
                    progressUpdate: progressUpdate))
        }
        let bootstrapper = ClusterBootstrapper(
            name: name,
            kubernetesVersion: configuration.kubernetesVersion,
            cni: cniManifestPath,
            fqdn: fqdn,
            sharedImageStore: sharedImageStore,
            controlPlane: controlPlane,
            workers: workerNodes.map(\.provisioner))

        // Record the cluster before provisioning, as `cluster create` does. Fails `.exists` for
        // a live duplicate and replaces a stale record.
        let records = ClusterClient()
        _ = try await records.create(configuration: configuration)

        let client = ContainerClient()
        do {
            try await provisionCluster(
                name: name,
                controlPlane: controlPlane,
                workers: workerNodes,
                initializeControlPlane: { controlPlaneName, vmIP, hasWorkers in
                    var sans = ["127.0.0.1"]
                    if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

                    await progressUpdate([.setDescription("Running kubeadm init")])
                    try await bootstrapper.bootstrapControlPlane(
                        nodeID: controlPlaneName,
                        apiServerSANs: sans,
                        advertiseAddress: vmIP,
                        schedulable: !hasWorkers,
                        client: client,
                        log: log)

                    guard hasWorkers else { return nil }
                    let join = try await bootstrapper.createJoinToken(
                        nodeID: controlPlaneName, client: client)
                    return JoinCredentials(token: join.token, caCertHash: join.caCertHash)
                },
                readinessPolicy: readinessPolicy,
                persistReadiness: { policy in
                    try await ClusterHelper.writeReadinessPolicy(policy, name: name, client: client)
                },
                finalizeCluster: {
                    if skipCNI {
                        await progressUpdate([.setDescription("Waiting for API server")])
                        try await ClusterHelper.waitForAPIServer(
                            containerId: name, client: client, log: log)
                    } else {
                        await progressUpdate([.setDescription("Waiting for cluster to be ready")])
                        try await ClusterHelper.waitForReady(
                            containerId: name, client: client, log: log)
                    }
                },
                log: log,
                progressUpdate: progressUpdate)
        } catch {
            // `.exists` means a container with this name is already there; the record may
            // belong to another live create.
            if (error as? ContainerizationError)?.code != .exists { try? await records.delete(name: name) }
            throw error
        }

        await progressUpdate([.setDescription("Writing kubeconfig")])
        do {
            let rawConfig = try await ClusterHelper.fetchConfig(
                containerId: name, client: client, log: log)
            let kubeConfig = try await ClusterHelper.transformConfig(
                rawConfig, containerId: name, fqdn: fqdn, client: client)
            try ClusterHelper.mergeConfig(
                kubeConfig, containerId: name, setCurrentContext: true, log: log)
        } catch {
            // Not fatal: the cluster is up, and only the kubeconfig is missing. Reported
            // rather than thrown so the caller keeps the cluster and can say how to recover.
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
            return CreateResult(kubeconfigWritten: false)
        }
        return CreateResult(kubeconfigWritten: true)
    }

    /// The size of each worker a create makes, in order: `workers` sized like the control
    /// plane, then each group's. Refuses a negative count and more than `maximumWorkers`.
    static func workerSizes(
        workers: Int, cpus: Int64?, memory: String?, groups: [WorkerGroup]
    ) throws -> [(cpus: Int64?, memory: String?)] {
        let counts = [workers] + groups.map(\.count)
        guard counts.allSatisfy({ $0 >= 0 }),
            counts.reduce(0, { $0 + $1 }) <= maximumWorkers
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "worker count must be between 0 and \(maximumWorkers)")
        }
        var sizes = Array(repeating: (cpus: cpus, memory: memory), count: workers)
        for group in groups {
            sizes += Array(repeating: (cpus: group.cpus, memory: group.memory), count: group.count)
        }
        return sizes
    }

    /// The cluster's kubeconfig as YAML, rewritten to reach the API server from this host —
    /// what `cluster write-config` writes, returned instead so an embedder can put it where the
    /// user asks.
    public static func kubeconfigYAML(name: String = K8sClusters.defaultName, log: Logger) async throws -> String {
        let client = ContainerClient()
        let fqdn = await ClusterHelper.detectFQDN(name: name)
        let rawConfig = try await ClusterHelper.fetchConfig(containerId: name, client: client, log: log)
        let config = try await ClusterHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
        return try YAMLEncoder().encode(config)
    }

    /// Start every stopped node in a cluster, control plane first, then wait for the whole
    /// cluster to answer again.
    public static func start(
        name: String = K8sClusters.defaultName, adoptLegacy: Bool = false,
        readiness: ClusterReadinessPolicy? = nil, log: Logger
    ) async throws {
        try await start(
            name: name, adoptLegacy: adoptLegacy, readiness: readiness,
            operations: LiveClusterStartup(client: ContainerClient(), log: log), log: log)
    }

    /// Stop every node of a cluster, workers first and the control plane last, so no worker
    /// loses its API server while it is still running. The nodes stay, and `start` brings
    /// them back; the kubeconfig is untouched.
    public static func stop(name: String = K8sClusters.defaultName, log: Logger) async throws {
        try await stop(name: name, containers: ContainerClient(), log: log)
    }

    /// The stop, with its container access injectable. Every stop carries the plugin labels
    /// and the incarnation observed in the listing, so a container that took a node's name in
    /// between is refused rather than stopped.
    static func stop(name: String, containers: any K8sClusterContainers, log: Logger) async throws {
        let listed = try await containers.listNodes()
        let clusterNodes = ClusterHelper.buildClusterRows(from: listed)
            .filter { $0.clusterName == name }
            .map(\.snapshot)
        guard let controlPlane = clusterNodes.first(where: { $0.id == name }) else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        var nodes = clusterNodes.filter { $0.id != name }
        nodes.sort { $0.id > $1.id }
        nodes.append(controlPlane)

        for node in nodes {
            try Task.checkCancellation()
            guard node.status == .running else {
                log.debug("cluster node already stopped", metadata: ["name": "\(node.id)"])
                continue
            }
            guard ClusterHelper.ownsNode(node.configuration.labels) else {
                throw ContainerizationError(.invalidArgument, message: "\(node.id) is not a cluster node")
            }
            var requiredLabels = nodeLabels(of: node)
            if node.configuration.labels[ResourceLabelKeys.cluster] != nil {
                requiredLabels[ResourceLabelKeys.cluster] = name
            }
            try await containers.stop(
                id: node.id,
                requiredLabels: requiredLabels,
                expectedIncarnation: node.incarnation)
            log.info("stopped cluster node", metadata: ["name": "\(node.id)"])
        }
    }

    /// Stop and remove a cluster, and drop its context from the default kubeconfig.
    public static func delete(
        name: String = K8sClusters.defaultName,
        expectedControlPlaneIncarnation: String? = nil,
        requiredLabels: [String: String]? = nil,
        log: Logger
    ) async throws {
        try await delete(
            name: name,
            expectedControlPlaneIncarnation: expectedControlPlaneIncarnation,
            requiredLabels: requiredLabels,
            containers: ContainerClient(),
            records: ClusterClient(),
            log: log)
    }

    /// The labels a container must carry to be treated as a cluster node here.
    static var nodeLabels: [String: String] { [ResourceLabelKeys.plugin: ClusterHelper.pluginName] }

    /// The plugin label a stop or delete of `node` requires: the one it carries, already checked
    /// to be this plugin's under its current or its earlier name.
    static func nodeLabels(of node: ContainerSnapshot) -> [String: String] {
        [ResourceLabelKeys.plugin: node.configuration.labels[ResourceLabelKeys.plugin] ?? ClusterHelper.pluginName]
    }

    /// The delete, with its container access injectable.
    ///
    /// Every node mutation carries both plugin ownership and the exact incarnation observed
    /// before any stop. Workers are removed before the control plane. A lookup/list failure
    /// performs no mutation, and kubeconfig and the cluster's record are kept until the whole
    /// guarded delete succeeds. `records` is nil where no cluster service is reachable, as in
    /// the unit tests.
    static func delete(
        name: String,
        expectedControlPlaneIncarnation: String? = nil,
        requiredLabels: [String: String]? = nil,
        containers: any K8sClusterContainers,
        records: (any K8sClusterRecords)? = nil,
        log: Logger
    ) async throws {
        let listed = try await containers.listNodes()
        let clusterNodes = ClusterHelper.buildClusterRows(from: listed)
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
                    // With an ownership condition, no observed node means no proof that
                    // this caller owns a same-name kubeconfig entry or record either. Without
                    // one, a record whose nodes are all gone (a `--rm` cluster) goes too.
                    if requiredLabels == nil {
                        try ClusterHelper.removeConfig(containerId: name, log: log)
                        try await removeRecord(name: name, records: records)
                    }
                    return
                }
                log.debug(
                    "control plane not found; deleting surviving cluster workers",
                    metadata: ["name": "\(name)"])
            }
        }
        if let controlPlane {
            guard ClusterHelper.ownsNode(controlPlane.configuration.labels) else {
                throw ContainerizationError(.invalidArgument, message: "\(name) is not a cluster")
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

        // Check the complete inventory before mutating any node, then carry the same
        // requirement through each engine-side stop/delete to close replacement races.
        for node in nodes {
            if let requiredLabels, !requiredLabels.allSatisfy({ node.configuration.labels[$0.key] == $0.value }) {
                throw ContainerizationError(.invalidArgument, message: "cluster node \(node.id) does not carry the labels this deletion requires")
            }
        }
        for node in nodes {
            guard ClusterHelper.ownsNode(node.configuration.labels) else {
                throw ContainerizationError(
                    .invalidArgument, message: "\(node.id) is not a cluster node")
            }
            if let owner = node.configuration.labels[ResourceLabelKeys.cluster], owner != name {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "\(node.id) belongs to cluster \(owner), not \(name)")
            }
            var requirements = (requiredLabels ?? [:]).merging(nodeLabels(of: node)) { _, plugin in plugin }
            if node.configuration.labels[ResourceLabelKeys.cluster] != nil {
                requirements[ResourceLabelKeys.cluster] = name
            }
            do {
                do {
                    try await containers.stop(
                        id: node.id,
                        requiredLabels: requirements,
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
                    requiredLabels: requirements,
                    expectedIncarnation: node.incarnation)
            } catch let error as ContainerizationError where error.code == .notFound {
                log.debug("cluster node not found, skipping delete", metadata: ["name": "\(node.id)"])
            }
        }

        try ClusterHelper.removeConfig(containerId: name, log: log)
        try await removeRecord(name: name, records: records)
    }

    /// Remove the cluster service's record of `name`, if it has one. A cluster created
    /// before the service kept records has none.
    static func removeRecord(name: String, records: (any K8sClusterRecords)?) async throws {
        guard let records else { return }
        do {
            try await records.delete(name: name)
        } catch let error as ContainerizationError where error.code == .invalidArgument || error.code == .notFound {
            // No record to remove: the name is not one the service can have recorded, or the cluster has none.
        }
    }
}

/// What `K8sClusters.delete` needs from the cluster service.
protocol K8sClusterRecords: Sendable {
    func delete(name: String) async throws
}

extension ClusterClient: K8sClusterRecords {}

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
            filters: ClusterHelper.nodeListFilters)
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
