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
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import TerminalProgress

private actor NodeIncarnations {
    private var values: [String: String] = [:]

    func record(_ incarnation: String, for name: String) { values[name] = incarnation }
    func incarnation(for name: String) -> String? { values[name] }
    func remove(_ name: String) { values.removeValue(forKey: name) }
}

/// A `NodeProvisioner` that runs a cluster node as a Linux container on the same host.
public struct LinuxNodeProvisioner: NodeProvisioner {
    public let name: String
    public let roles: [String]

    private let labels: [String: String]
    private let clusterName: String
    private let nodeImage: String?
    private let cpus: Int64?
    private let memory: String?
    private let registryScheme: String
    private let maxConcurrentDownloads: Int
    private let remove: Bool
    private let containerSystemConfig: ContainerSystemConfig
    private let fqdn: String?
    private let sharedImageStore: Bool
    private let progressUpdate: ProgressUpdateHandler
    private let incarnations: NodeIncarnations

    /// - Parameters:
    ///   - name: Name of this node. The control plane is named after the cluster;
    ///     workers use `ClusterHelper.workerName(cluster:index:)`.
    ///   - clusterName: The cluster this node belongs to.
    public init(
        name: String,
        clusterName: String,
        labels: [String: String] = [:],
        roles: [String] = [StandardRoles.controlPlane],
        nodeImage: String? = nil,
        cpus: Int64? = nil,
        memory: String? = nil,
        registryScheme: String = "https",
        maxConcurrentDownloads: Int = 3,
        remove: Bool = false,
        containerSystemConfig: ContainerSystemConfig,
        fqdn: String? = nil,
        sharedImageStore: Bool = false,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) throws {
        guard !roles.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "LinuxNode roles must not be empty")
        }
        let known: Set<String> = [StandardRoles.controlPlane, StandardRoles.worker]
        let unrecognized = roles.filter { !known.contains($0) }
        guard unrecognized.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "LinuxNode roles contains unrecognized values: \(unrecognized.joined(separator: ", "))")
        }
        self.name = name
        self.labels = labels
        self.clusterName = clusterName
        self.roles = roles
        self.nodeImage = nodeImage
        self.cpus = cpus
        self.memory = memory
        self.registryScheme = registryScheme
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.remove = remove
        self.containerSystemConfig = containerSystemConfig
        self.fqdn = fqdn
        self.sharedImageStore = sharedImageStore
        self.progressUpdate = progressUpdate
        self.incarnations = NodeIncarnations()
    }

    /// Extra metadata travels with every node, without changing its reserved identity.
    var managementLabels: [String] {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + [
            "\(ResourceLabelKeys.plugin)=\(ClusterHelper.pluginName)",
            "\(ResourceLabelKeys.cluster)=\(clusterName)",
            "\(ResourceLabelKeys.role)=\(roles.joined(separator: ","))",
        ]
    }

    public func provision(log: Logger) async throws {
        let resolvedImage = nodeImage ?? ClusterHelper.nodeImage
        var volumes: [String] = []
        if sharedImageStore {
            _ = try await ClusterHelper.clusterShimURL(log: log)
            let hostStoreSocket = ClusterHelper.hostStoreSocketPath.string
            try ClusterHelper.checkHostStoreSocket(hostStoreSocket)
            volumes.append("\(hostStoreSocket):\(ClusterHelper.nodeHostStoreSocketPath)")
        }
        try await ClusterHelper.ensureImage(nodeImage: resolvedImage, log: log, containerSystemConfig: containerSystemConfig)

        let isControlPlane = roles.contains(StandardRoles.controlPlane)
        let stateRoot = try PluginStateRoot(plugin: ClusterHelper.pluginName).path
        try FileManager.default.createDirectory(atPath: stateRoot.string, withIntermediateDirectories: true)
        let portLock = open(stateRoot.appending("port.lock").string, O_CREAT | O_RDONLY, 0o600)
        defer { close(portLock) }
        if isControlPlane && fqdn == nil { flock(portLock, LOCK_EX) }
        let publishPorts = isControlPlane && fqdn == nil ? [try await ClusterHelper.clusterPort()] : []

        let management = Flags.Management(
            addHosts: [],
            arch: Arch.hostArchitecture().rawValue,
            capAdd: ["ALL"],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: .init(domain: nil, nameservers: [], options: [], searchDomains: []),
            dnsDisabled: false,
            entrypoint: "/bin/sh",
            hostname: nil,
            initImage: nil,
            kernel: nil,
            kernelArgs: [],
            labels: managementLabels,
            maskedPaths: [],
            mounts: [],
            name: name,
            networks: [],
            os: "linux",
            platform: nil,
            publishPorts: publishPorts,
            publishSockets: [],
            readOnly: false,
            readonlyPaths: [],
            remove: remove,
            restart: nil,
            rosetta: true,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            sysctls: [],
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: volumes
        )

        let updatedResource = ClusterHelper.defaultedResourceFlags(Flags.Resource(cpus: cpus, memory: memory))
        let processFlags = Flags.Process(
            cwd: nil,
            env: ClusterHelper.nodeProxyEnv(),
            envFile: [],
            gid: nil,
            interactive: false,
            tty: false,
            uid: nil,
            ulimits: [],
            user: nil
        )

        var (config, kernel, initfs) = try await Utility.containerConfigFromFlags(
            id: name,
            image: resolvedImage,
            arguments: ["-c", ClusterHelper.nodeEntrypointScript, "sh", "/sbin/init"],
            process: processFlags,
            management: management,
            resource: updatedResource,
            registry: Flags.Registry(scheme: registryScheme),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: maxConcurrentDownloads),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: progressUpdate,
            log: log
        )
        config.maskedPaths = []
        config.readonlyPaths = []
        config.writableSysfs = true

        let client = ContainerClient()
        // Choose and retain the destructive identity before the request. If cancellation or
        // disconnect happens after the server commits but before its reply arrives, cluster
        // rollback can still target exactly the container this attempt asked it to create.
        let requestedIncarnation = UUID().uuidString.lowercased()
        await incarnations.record(requestedIncarnation, for: name)
        let incarnation = try await client.create(
            configuration: config,
            options: ContainerCreateOptions(autoRemove: remove),
            kernel: kernel,
            initImage: initfs,
            incarnation: requestedIncarnation
        )
        flock(portLock, LOCK_UN)
        guard incarnation == requestedIncarnation else {
            throw ContainerizationError(
                .internalError,
                message: "container \(name) did not keep its requested incarnation")
        }

        // The container exists from here on, so remove it if a later step fails; the caller
        // only tears down nodes whose `provision` succeeded.
        do {
            let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
            defer { try? io.close() }
            let process = try await client.bootstrap(id: name, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()

            try await ClusterHelper.waitForNodeBooted(containerId: name, client: client, log: log)
            try await prepareNode(nodeID: name, client: client, log: log)
        } catch {
            // Only the container this attempt created: a same-name replacement is left alone.
            let required = [ResourceLabelKeys.plugin: ClusterHelper.pluginName]
            try? await client.stop(id: name, requiredLabels: required, expectedIncarnation: requestedIncarnation)
            try? await client.delete(id: name, requiredLabels: required, expectedIncarnation: requestedIncarnation)
            await incarnations.remove(name)
            throw error
        }
    }

    public func address(log: Logger) async throws -> String {
        let client = ContainerClient()
        let snapshot = try await client.get(id: name)
        guard let ip = snapshot.networks.first?.ipv4Address.address.description else {
            throw ContainerizationError(.internalError, message: "no VM IP for node \(name)")
        }
        return ip
    }

    public func join(
        controlPlaneEndpoint: String,
        token: String,
        caCertHash: String,
        log: Logger
    ) async throws {
        let client = ContainerClient()
        let (code, output) = try await ClusterHelper.execCapture(
            containerId: name,
            executable: ClusterHelper.kubeadmPath,
            arguments: [
                "join", controlPlaneEndpoint,
                "--token", token,
                "--discovery-token-ca-cert-hash", caCertHash,
                "--ignore-preflight-errors", ClusterHelper.ignorePreflightErrors,
                "--cri-socket", "unix:///run/containerd/containerd.sock",
            ],
            client: client)
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm join failed on \(name): \(output)")
        }
    }

    public func waitForReady(log: Logger) async throws {
        let timeout = 180
        let client = ContainerClient()
        log.info("Waiting for node to become ready", metadata: ["node": "\(name)"])
        for attempt in 1...timeout {
            let code: Int32
            do {
                code = try await ClusterHelper.runProbe(
                    client: client,
                    containerId: clusterName,
                    arguments: ["wait", "--for=condition=Ready", "node/\(name)", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "node \(name) stopped unexpectedly while waiting for readiness: \(error)")
            }
            if code == 0 { return }
            if attempt == timeout {
                throw ContainerizationError(
                    .timeout,
                    message: "node \(name) did not become Ready within \(timeout * 2)s")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// Run `sync` in the node. Its disk caches writes, and ext4 allocates a file's blocks
    /// only when the page cache writes them back, so a VM killed within about thirty
    /// seconds of kubeadm writing the kubelet's config boots with that file empty and the
    /// kubelet never starts again.
    public func persist(log: Logger) async throws {
        let (code, output) = try await ClusterHelper.execCapture(
            containerId: name, executable: "/bin/sync", arguments: [], client: ContainerClient())
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "sync failed on \(name): \(output)")
        }
    }

    /// Wait until the node is registered with the API server, without requiring it to be Ready.
    /// Used when no CNI is installed, since nodes stay NotReady without one.
    public func waitForRegistered(log: Logger) async throws {
        let timeout = 180
        let client = ContainerClient()
        log.info("Waiting for node to register", metadata: ["node": "\(name)"])
        for attempt in 1...timeout {
            let code: Int32
            do {
                code = try await ClusterHelper.runProbe(
                    client: client,
                    containerId: clusterName,
                    arguments: ["get", "node/\(name)", "--request-timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "node \(name) stopped unexpectedly while waiting for registration: \(error)")
            }
            if code == 0 { return }
            if attempt == timeout {
                throw ContainerizationError(
                    .timeout,
                    message: "node \(name) did not register within \(timeout * 2)s")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    public func teardown(log: Logger) async throws {
        let client = ContainerClient()
        let container: ContainerSnapshot
        do {
            container = try await client.get(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            return
        }
        guard container.configuration.labels[ResourceLabelKeys.plugin] == ClusterHelper.pluginName else {
            log.warning(
                "container exists but is not owned by this plugin, refusing teardown",
                metadata: ["name": "\(name)"])
            return
        }
        do {
            guard let incarnation = await incarnations.incarnation(for: name) else {
                throw ContainerizationError(
                    .invalidState,
                    message: "no observed incarnation exists for node \(name)")
            }
            let required = [ResourceLabelKeys.plugin: ClusterHelper.pluginName]
            try? await client.stop(
                id: name,
                requiredLabels: required,
                expectedIncarnation: incarnation)
            try await client.delete(
                id: name,
                requiredLabels: required,
                expectedIncarnation: incarnation)
            await incarnations.remove(name)
        } catch let error as ContainerizationError where error.code == .notFound {
            await incarnations.remove(name)
            log.debug("node container not found, skipping delete", metadata: ["name": "\(name)"])
        }
    }

    /// Configures the node. With `sharedImageStore`, it also installs cluster-shim
    /// so the node can use images from the host image store.
    private func prepareNode(nodeID: String, client: ContainerClient, log: Logger) async throws {
        log.info("Preparing node", metadata: ["id": "\(nodeID)", "sharedImageStore": "\(sharedImageStore)"])
        var script = Self.nodePrepScript
        if sharedImageStore {
            let shim = try await ClusterHelper.clusterShimURL(log: log)
            try await client.copyIn(id: nodeID, source: shim.path, destination: ClusterHelper.nodeShimPath, mode: 0o755)
            script = script + "\n" + Self.hostImagesScript
        }

        let result = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", script], client: client)
        guard result.code == 0 else {
            throw ContainerizationError(.internalError, message: "node prep failed on \(nodeID): \(result.output)")
        }
    }

    /// Installs and starts cluster-shim as a systemd service. The kubelet uses it
    /// as its image service, set in `ClusterBootstrapper.initConfigYAML`.
    private static var hostImagesScript: String {
        """
        set -e
        cat > /etc/systemd/system/cluster-shim.service <<'EOF'
        [Unit]
        Description=container cluster host image service
        After=containerd.service

        [Service]
        ExecStart=\(ClusterHelper.nodeShimPath)
        Restart=always

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now cluster-shim
        """
    }

    /// Configures containerd, networking and the pause image for the cluster.
    private static var nodePrepScript: String {
        """
        set -e
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/native-snapshotter.toml <<'EOF'
        [plugins.'io.containerd.cri.v1.images']
          snapshotter = "native"
        EOF
        sysctl -w net.ipv4.ip_forward=1                 2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-iptables=1  2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
        systemctl restart containerd
        ctr -n k8s.io images tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1 2>/dev/null || true
        /usr/sbin/iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        /usr/sbin/iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        """
    }
}
