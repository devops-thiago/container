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

    /// Create and start a single-node cluster. The steps and their order are `k8s create`'s.
    @discardableResult
    public static func create(
        name: String = K8sClusters.defaultName,
        nodeImage: String = K8sClusters.defaultNodeImage,
        cpus: Int64? = nil,
        memory: String? = nil,
        autoRemove: Bool = false,
        registry: Flags.Registry = Flags.Registry(scheme: "https"),
        imageFetch: Flags.ImageFetch = Flags.ImageFetch(maxConcurrentDownloads: 3),
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws -> CreateResult {
        guard nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "cluster name \(name) is not a valid container ID")
        }

        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
        try await K8sHelper.ensureImage(nodeImage: nodeImage, log: log, containerSystemConfig: containerSystemConfig)

        let fqdn = K8sHelper.fqdn(for: name, domain: containerSystemConfig.dns.domain)
        let dns = Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: [])

        let management = Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: ["ALL"],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: dns,
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: nil,
            kernelArgs: [],
            labels: [
                "\(ResourceLabelKeys.plugin)=\(K8sHelper.pluginName)",
                "\(ResourceLabelKeys.role)=\(K8sHelper.controlPlaneRoleName)",
            ],
            maskedPaths: [],
            mounts: [],
            name: name,
            networks: [],
            os: "linux",
            platform: nil,
            publishPorts: fqdn == nil ? [try await K8sHelper.clusterPort()] : [],
            publishSockets: [],
            readOnly: false,
            readonlyPaths: [],
            remove: autoRemove,
            rosetta: true,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: []
        )

        let updatedResource = K8sHelper.defaultedResourceFlags(Flags.Resource(cpus: cpus, memory: memory))
        let processFlags = Flags.Process(
            cwd: nil, env: K8sHelper.nodeProxyEnv(), envFile: [], gid: nil, interactive: false,
            tty: false, uid: nil, ulimits: [], user: nil)

        var (config, kernel, initfs) = try await Utility.containerConfigFromFlags(
            id: name,
            image: nodeImage,
            arguments: [],
            process: processFlags,
            management: management,
            resource: updatedResource,
            registry: registry,
            imageFetch: imageFetch,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progressUpdate,
            log: log
        )

        // Allow the node to modify /proc/sys (e.g. net.ipv4.ip_forward) during setup.
        config.maskedPaths = []
        config.readonlyPaths = []

        let client = ContainerClient()
        let options = ContainerCreateOptions(autoRemove: autoRemove)
        try await client.create(
            configuration: config,
            options: options,
            kernel: kernel,
            initImage: initfs
        )

        await progressUpdate([.setDescription("Starting cluster")])
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: name, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()

        await progressUpdate([.setDescription("Waiting for node to boot")])
        try await K8sHelper.waitForNodeBooted(containerId: name, client: client, log: log)

        let snapshot = try await client.get(id: name)
        guard let vmIP = snapshot.networks.first?.ipv4Address.address.description else {
            throw ContainerizationError(.internalError, message: "no VM IP for control plane \(name)")
        }
        var sans = ["127.0.0.1"]
        if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

        await progressUpdate([.setDescription("Running kubeadm init")])
        try await K8sHelper.prepareNode(nodeID: name, client: client, log: log)
        // A single-node cluster is its own worker, so the control-plane taint has to go —
        // the same answer `k8s create` gives for its default roles.
        try await K8sHelper.bootstrapControlPlane(
            nodeID: name, apiServerSANs: sans, advertiseAddress: vmIP,
            schedulable: true, client: client, log: log)

        await progressUpdate([.setDescription("Waiting for cluster to be ready")])
        try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

        await progressUpdate([.setDescription("Writing kubeconfig")])
        do {
            let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
            let kubeConfig = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(kubeConfig, containerId: name, setCurrentContext: true, log: log)
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

    /// Start a stopped cluster and wait until it answers again. The steps are `k8s start`'s.
    public static func start(name: String = K8sClusters.defaultName, log: Logger) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: name)

        guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }

        if container.status == .running { return }

        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: name, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()

        try await K8sHelper.waitForNodeBooted(containerId: name, client: client, log: log)
        // Idempotent, and it heals clusters created before the loopback pin existed: their
        // admin kubeconfigs still name whatever address the node had at kubeadm init.
        try await K8sHelper.pinAdminKubeconfigsToLoopback(nodeID: name, client: client)
        try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

        do {
            let fqdn = await K8sHelper.detectFQDN(name: name)
            let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
            let config = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(config, containerId: name, log: log)
        } catch {
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
        }
    }

    /// Stop and remove a cluster, and drop its context from the default kubeconfig.
    public static func delete(name: String = K8sClusters.defaultName, log: Logger) async throws {
        try await delete(name: name, containers: ContainerClient(), log: log)
    }

    /// The labels a container must carry to be treated as a cluster node here.
    static var nodeLabels: [String: String] { [ResourceLabelKeys.plugin: K8sHelper.pluginName] }

    /// The delete, with its container access injectable.
    ///
    /// Fails closed: a lookup that errors performs no stop and no delete, because "could not
    /// read it" is not "it is a cluster node". Only a definite not-found skips to the
    /// kubeconfig cleanup. The stop and delete then carry the node labels as a requirement
    /// the service re-checks against whatever the ID names when it acts, so an ordinary
    /// container that took the name in between is refused rather than destroyed.
    static func delete(name: String, containers: any K8sClusterContainers, log: Logger) async throws {
        let container: ContainerSnapshot
        do {
            container = try await containers.get(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("cluster container not found, skipping delete", metadata: ["name": "\(name)"])
            try K8sHelper.removeConfig(containerId: name, log: log)
            return
        }
        guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }

        do {
            do {
                try await containers.stop(id: name, requiredLabels: nodeLabels)
            } catch let error as ContainerizationError where error.code == .invalidArgument {
                // The refusal that says the ID no longer names our node. Not the idempotent
                // "already stopped" the stop otherwise tolerates.
                throw error
            } catch {
                log.debug("cluster stop before delete failed; deleting anyway", metadata: ["name": "\(name)", "error": "\(error)"])
            }
            try await containers.delete(id: name, requiredLabels: nodeLabels)
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("cluster container not found, skipping delete", metadata: ["name": "\(name)"])
        }

        try K8sHelper.removeConfig(containerId: name, log: log)
    }
}

/// What `K8sClusters.delete` needs from the engine, so a test can stand in for it.
protocol K8sClusterContainers: Sendable {
    func get(id: String) async throws -> ContainerSnapshot
    func stop(id: String, requiredLabels: [String: String]) async throws
    func delete(id: String, requiredLabels: [String: String]) async throws
}

extension ContainerClient: K8sClusterContainers {
    func stop(id: String, requiredLabels: [String: String]) async throws {
        try await stop(id: id, opts: .default, requiredLabels: requiredLabels)
    }

    func delete(id: String, requiredLabels: [String: String]) async throws {
        try await delete(id: id, force: false, requiredLabels: requiredLabels)
    }
}
