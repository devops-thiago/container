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

    /// Create and start a single-node cluster. The steps and their order are `k8s create`'s.
    public static func create(
        name: String = K8sClusters.defaultName,
        nodeImage: String = K8sClusters.defaultNodeImage,
        cpus: Int64? = nil,
        memory: String? = nil,
        autoRemove: Bool = false,
        registry: Flags.Registry = Flags.Registry(scheme: "auto"),
        imageFetch: Flags.ImageFetch = Flags.ImageFetch(maxConcurrentDownloads: 3),
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws {
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
        try await K8sHelper.bootstrapControlPlane(
            nodeID: name, apiServerSANs: sans, advertiseAddress: vmIP,
            client: client, log: log)

        await progressUpdate([.setDescription("Waiting for cluster to be ready")])
        try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

        await progressUpdate([.setDescription("Writing kubeconfig")])
        do {
            let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
            let kubeConfig = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(kubeConfig, containerId: name, setCurrentContext: true, log: log)
        } catch {
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
        }
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
        let client = ContainerClient()

        if let container = try? await client.get(id: name) {
            guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
                throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
            }
        }

        do {
            try? await client.stop(id: name)
            try await client.delete(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("cluster container not found, skipping delete", metadata: ["name": "\(name)"])
        }

        try K8sHelper.removeConfig(containerId: name, log: log)
    }
}
