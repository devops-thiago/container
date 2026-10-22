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

/// What a view of a container depends on besides the container: the time it is seen at, for
/// "Up 5 minutes", which engine network is the one Docker calls `bridge`, and the image IDs of
/// the engine's images by the digest of what their references name.
public struct DockerViewContext: Sendable {
    public var now: Date
    public var builtinNetwork: String?
    /// Image ID (the host platform's config digest) by index digest, for the containers this
    /// service did not create: the engine records only the index they were made from.
    public var imageIDs: [String: String]

    public init(now: Date, builtinNetwork: String?, imageIDs: [String: String] = [:]) {
        self.now = now
        self.builtinNetwork = builtinNetwork
        self.imageIDs = imageIDs
    }
}

/// Docker's container states, as `State.Status` and the `status` filter spell them.
public enum DockerContainerStatus: String, Sendable, CaseIterable {
    case created
    case running
    case paused
    case restarting
    case removing
    case exited
    case dead
}

/// An engine container as `GET /containers/json` and `GET /containers/{id}/json` show it.
public enum ContainerViewMapper {
    /// Docker's zero time, which it shows for "never".
    public static let zeroTime = "0001-01-01T00:00:00Z"

    /// The engine's status in Docker's words. A container that is stopping still runs; one the
    /// engine does not know the state of is shown by whether it ever ran.
    public static func status(_ snapshot: ContainerSnapshot) -> DockerContainerStatus {
        switch snapshot.status {
        case .running, .stopping:
            return .running
        case .restarting:
            return .restarting
        case .stopped, .unknown:
            return hasRun(snapshot) ? .exited : .created
        }
    }

    static func hasRun(_ snapshot: ContainerSnapshot) -> Bool {
        snapshot.startedDate != nil || snapshot.exitCode != nil || snapshot.exitedAt != nil
    }

    /// Whether `docker ps` without `-a` lists it: dockerd counts a restarting container as
    /// running.
    public static func isRunning(_ snapshot: ContainerSnapshot) -> Bool {
        [.running, .restarting].contains(status(snapshot))
    }

    /// The `Status` column: `Up 5 minutes (healthy)`, `Exited (0) 3 seconds ago`, `Created`.
    public static func statusText(_ snapshot: ContainerSnapshot, now: Date) -> String {
        switch status(snapshot) {
        case .running:
            var text = snapshot.startedDate.map { "Up \(humanDuration(now.timeIntervalSince($0)))" } ?? "Up"
            switch snapshot.health?.status {
            case .healthy: text += " (healthy)"
            case .unhealthy: text += " (unhealthy)"
            case .starting: text += " (health: starting)"
            case nil: break
            }
            return text
        case .restarting:
            return "Restarting (\(snapshot.exitCode ?? 0)) " + (snapshot.exitedAt.map { "\(humanDuration(now.timeIntervalSince($0))) ago" } ?? "")
        case .exited:
            let code = "Exited (\(snapshot.exitCode ?? 0))"
            return snapshot.exitedAt.map { "\(code) \(humanDuration(now.timeIntervalSince($0))) ago" } ?? code
        default:
            return "Created"
        }
    }

    /// How long, in the words `docker ps` uses.
    public static func humanDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 1 { return "Less than a second" }
        if seconds == 1 { return "1 second" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes == 1 { return "About a minute" }
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = Int((interval / 3600).rounded())
        if hours == 1 { return "About an hour" }
        if hours < 48 { return "\(hours) hours" }
        if hours < 24 * 7 * 2 { return "\(hours / 24) days" }
        if hours < 24 * 30 * 2 { return "\(hours / 24 / 7) weeks" }
        if hours < 24 * 365 * 2 { return "\(hours / 24 / 30) months" }
        return "\(Int(interval / 3600) / 24 / 365) years"
    }

    /// A time as dockerd writes one, or its zero time.
    public static func timestamp(_ date: Date?) -> String {
        guard let date else { return zeroTime }
        return Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt).format(date)
    }

    /// The image as the client named it, or the engine's normalized reference made familiar
    /// again (`docker.io/library/alpine:latest` as `alpine:latest`).
    public static func image(_ container: DockerContainer) -> String {
        if let image = container.extras?.image ?? container.snapshot.configuration.labels[DockerLabels.image] {
            return image
        }
        return shortReference(container.snapshot.configuration.image.reference)
    }

    /// An image reference as a Docker client writes it: without Docker Hub's `docker.io/library/`.
    static func shortReference(_ normalized: String) -> String {
        var reference = normalized
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            reference.removeFirst(prefix.count)
            break
        }
        return reference
    }

    /// The image's ID as this service recorded it at create; for another container, the
    /// engine's index digest.
    public static func imageID(_ container: DockerContainer) -> String {
        container.extras?.imageID ?? container.snapshot.configuration.labels[DockerLabels.imageID] ?? container.snapshot.configuration.image.digest
    }

    /// The image's ID as `GET /images/json` reports it: as recorded at create, else the config
    /// digest of the index the engine recorded, else that index's digest.
    public static func imageID(_ container: DockerContainer, context: DockerViewContext) -> String {
        let digest = container.snapshot.configuration.image.digest
        return container.extras?.imageID ?? container.snapshot.configuration.labels[DockerLabels.imageID] ?? context.imageIDs[digest] ?? digest
    }

    /// The labels a client set, without this service's own.
    public static func labels(_ container: DockerContainer) -> [String: String] {
        container.snapshot.configuration.labels.filter { !$0.key.hasPrefix(DockerLabels.prefix) }
    }

    static func networkName(_ network: String, context: DockerViewContext) -> String {
        network == context.builtinNetwork ? "bridge" : network
    }

    static func command(_ process: ProcessConfiguration) -> String {
        ([process.executable] + process.arguments).joined(separator: " ")
    }

    static func user(_ user: ProcessConfiguration.User) -> String {
        switch user {
        case .raw(let text): text
        case .id(0, 0): ""
        case .id(let uid, let gid): "\(uid):\(gid)"
        }
    }

    /// Each published port, one per port of a range.
    static func expandedPorts(_ configuration: ContainerConfiguration) -> [(host: PublishPort, offset: UInt16)] {
        configuration.publishedPorts.flatMap { port in (0..<port.count).map { (port, $0) } }
    }

    static func portKey(_ port: PublishPort, offset: UInt16) -> String {
        "\(port.containerPort + offset)/\(port.proto.rawValue)"
    }

    static func exposedPorts(_ container: DockerContainer) -> [String] {
        Set(container.extras?.exposedPorts ?? []).union(expandedPorts(container.snapshot.configuration).map { portKey($0.host, offset: $0.offset) }).sorted()
    }

    static func ports(_ container: DockerContainer) -> [DockerPort] {
        let published = expandedPorts(container.snapshot.configuration)
        var ports = published.map { port, offset in
            DockerPort(
                IP: port.hostAddress.description, PrivatePort: Int(port.containerPort + offset), PublicPort: Int(port.hostPort + offset),
                type: port.proto.rawValue)
        }
        let publishedKeys = Set(published.map { portKey($0.host, offset: $0.offset) })
        for key in container.extras?.exposedPorts ?? [] where !publishedKeys.contains(key) {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard let number = Int(parts[0]) else { continue }
            ports.append(DockerPort(IP: nil, PrivatePort: number, PublicPort: nil, type: parts.count > 1 ? String(parts[1]) : "tcp"))
        }
        return ports
    }

    static func portBindings(_ configuration: ContainerConfiguration) -> [String: [DockerPortBinding]] {
        var bindings: [String: [DockerPortBinding]] = [:]
        for (port, offset) in expandedPorts(configuration) {
            let address = port.hostAddress.description
            bindings[portKey(port, offset: offset), default: []].append(
                DockerPortBinding(HostIp: address == "0.0.0.0" ? "" : address, HostPort: "\(port.hostPort + offset)"))
        }
        return bindings
    }

    static func mounts(_ configuration: ContainerConfiguration) -> [DockerMountPoint] {
        configuration.mounts.map { mount in
            let readOnly = mount.options.readonly
            if let name = mount.volumeName {
                return DockerMountPoint(
                    type: "volume", Name: name, Source: mount.source, Destination: mount.destination, Driver: "local", Mode: readOnly ? "ro" : "z",
                    RW: !readOnly, Propagation: "")
            }
            if mount.isTmpfs {
                return DockerMountPoint(
                    type: "tmpfs", Name: nil, Source: "", Destination: mount.destination, Driver: nil, Mode: "", RW: !readOnly, Propagation: "")
            }
            return DockerMountPoint(
                type: "bind", Name: nil, Source: mount.source, Destination: mount.destination, Driver: nil, Mode: readOnly ? "ro" : "", RW: !readOnly,
                Propagation: "rprivate")
        }
    }

    static func endpoint(_ attachment: Attachment, container: DockerContainer) -> DockerEndpoint {
        DockerEndpoint(
            Aliases: attachment.aliases.isEmpty ? nil : attachment.aliases,
            NetworkID: attachment.network,
            EndpointID: "",
            Gateway: attachment.ipv4Gateway.description,
            IPAddress: attachment.ipv4Address.address.description,
            IPPrefixLen: Int(attachment.ipv4Address.prefix.length),
            IPv6Gateway: "",
            GlobalIPv6Address: attachment.ipv6Address?.address.description ?? "",
            GlobalIPv6PrefixLen: attachment.ipv6Address.map { Int($0.prefix.length) } ?? 0,
            MacAddress: attachment.macAddress?.description ?? "",
            DNSNames: [container.name, ContainerHostname.default(for: container.engineID)])
    }

    static func networks(_ container: DockerContainer, context: DockerViewContext) -> [String: DockerEndpoint] {
        // The configured networks while stopped, the attached ones while running.
        let attached = container.snapshot.networks
        if !attached.isEmpty {
            return Dictionary(
                attached.map { (networkName($0.network, context: context), endpoint($0, container: container)) }, uniquingKeysWith: { first, _ in first })
        }
        return Dictionary(
            container.snapshot.configuration.networks.map { configured in
                (
                    networkName(configured.network, context: context),
                    DockerEndpoint(
                        Aliases: configured.options.aliases.isEmpty ? nil : configured.options.aliases, NetworkID: configured.network, EndpointID: "",
                        Gateway: "", IPAddress: "", IPPrefixLen: 0, IPv6Gateway: "", GlobalIPv6Address: "", GlobalIPv6PrefixLen: 0, MacAddress: "",
                        DNSNames: nil)
                )
            }, uniquingKeysWith: { first, _ in first })
    }

    public static func summary(_ container: DockerContainer, context: DockerViewContext) -> DockerContainerSummary {
        let configuration = container.snapshot.configuration
        return DockerContainerSummary(
            Id: container.dockerID,
            Names: ["/" + container.name],
            Image: image(container),
            ImageID: imageID(container, context: context),
            Command: command(configuration.initProcess),
            Created: Int64(configuration.creationDate.timeIntervalSince1970),
            Ports: ports(container),
            Labels: labels(container),
            State: status(container.snapshot).rawValue,
            Status: statusText(container.snapshot, now: context.now),
            HostConfig: .init(NetworkMode: container.extras?.networkMode ?? "bridge"),
            NetworkSettings: .init(Networks: networks(container, context: context)),
            Mounts: mounts(configuration))
    }

    /// `SizeRw` in a list or `GET /system/df`, which dockerd leaves out when it is zero.
    static func listedSize(_ size: Int64?) -> Int64? {
        size == 0 ? nil : size
    }

    public static func inspect(_ container: DockerContainer, context: DockerViewContext) -> DockerContainerInspect {
        let snapshot = container.snapshot
        let configuration = snapshot.configuration
        let process = configuration.initProcess
        let status = status(snapshot)
        let networks = networks(container, context: context)
        let bridge = networks["bridge"]
        var exposed: [String: DockerEmptyObject] = [:]
        for key in exposedPorts(container) { exposed[key] = DockerEmptyObject() }
        let published = portBindings(configuration)
        var ports: [String: [DockerPortBinding]?] = [:]
        for key in exposed.keys {
            ports[key] =
                published[key].map { bindings in
                    bindings.map { DockerPortBinding(HostIp: ($0.HostIp ?? "").isEmpty ? "0.0.0.0" : $0.HostIp, HostPort: $0.HostPort) }
                } ?? nil
        }
        let restart = configuration.restartPolicy ?? .no
        let restartName: String
        let maxRetries: Int
        switch restart {
        case .onFailure(let retries):
            restartName = "on-failure"
            maxRetries = retries ?? 0
        default:
            restartName = restart.description
            maxRetries = 0
        }
        let health = configuration.healthCheck.map {
            DockerHealthConfig(
                Test: $0.test, Interval: $0.interval, Timeout: $0.timeout, StartPeriod: $0.startPeriod, StartInterval: $0.startInterval,
                Retries: $0.retries)
        }
        let binds = configuration.mounts.filter(\.isVirtiofs).map { "\($0.source):\($0.destination)" + ($0.options.readonly ? ":ro" : "") }
        let extras = container.extras
        var volumes: [String: DockerEmptyObject] = [:]
        for volume in extras?.volumes ?? [] { volumes[volume] = DockerEmptyObject() }

        return DockerContainerInspect(
            Id: container.dockerID,
            Created: timestamp(configuration.creationDate),
            Path: process.executable,
            Args: process.arguments,
            State: DockerContainerState(
                Status: status.rawValue,
                Running: status == .running || status == .restarting,
                Paused: false,
                Restarting: status == .restarting,
                OOMKilled: snapshot.oomKilled ?? false,
                Dead: false,
                Pid: 0,
                ExitCode: Int(snapshot.exitCode ?? 0),
                Error: snapshot.restartError ?? "",
                StartedAt: timestamp(snapshot.startedDate),
                FinishedAt: status == .running ? zeroTime : timestamp(snapshot.exitedAt),
                Health: snapshot.health.map { health in
                    DockerHealth(
                        Status: health.status.rawValue, FailingStreak: health.failingStreak,
                        Log: health.log.map {
                            .init(Start: timestamp($0.start), End: timestamp($0.end), ExitCode: Int($0.exitCode), Output: $0.output)
                        })
                }),
            Image: imageID(container, context: context),
            ResolvConfPath: "",
            HostnamePath: "",
            HostsPath: "",
            LogPath: "",
            Name: "/" + container.name,
            RestartCount: snapshot.restartCount,
            Driver: "virtiofs",
            Platform: configuration.platform.os,
            MountLabel: "",
            ProcessLabel: "",
            AppArmorProfile: "",
            HostConfig: DockerHostConfigView(
                Binds: binds.isEmpty ? nil : binds,
                NetworkMode: extras?.networkMode ?? "bridge",
                PortBindings: published,
                RestartPolicy: DockerRestartPolicy(Name: restartName, MaximumRetryCount: maxRetries),
                AutoRemove: extras?.autoRemove ?? false,
                CapAdd: configuration.capAdd.isEmpty ? nil : configuration.capAdd,
                CapDrop: configuration.capDrop.isEmpty ? nil : configuration.capDrop,
                Dns: configuration.dns?.nameservers ?? [],
                DnsOptions: configuration.dns?.options ?? [],
                DnsSearch: configuration.dns?.searchDomains ?? [],
                ExtraHosts: configuration.extraHosts.isEmpty ? nil : configuration.extraHosts.map { "\($0.name):\($0.address)" },
                Privileged: false,
                PublishAllPorts: extras?.publishAllPorts ?? false,
                ReadonlyRootfs: configuration.readOnly,
                ShmSize: Int64(configuration.shmSize ?? 64 * 1024 * 1024),
                Sysctls: configuration.sysctls.isEmpty ? nil : configuration.sysctls,
                Memory: Int64(clamping: configuration.resources.memoryInBytes),
                NanoCpus: Int64(configuration.resources.cpus) * 1_000_000_000,
                Init: configuration.useInit ? true : nil,
                LogConfig: DockerLogConfig(type: "json-file")),
            Mounts: mounts(configuration),
            Config: DockerContainerConfigView(
                Hostname: configuration.hostname ?? ContainerHostname.default(for: container.engineID),
                Domainname: extras?.domainname ?? "",
                User: user(process.user),
                AttachStdin: extras?.attachStdin ?? false,
                AttachStdout: extras?.attachStdout ?? false,
                AttachStderr: extras?.attachStderr ?? false,
                ExposedPorts: exposed.isEmpty ? nil : exposed,
                Tty: process.terminal,
                OpenStdin: extras?.openStdin ?? false,
                StdinOnce: extras?.stdinOnce ?? false,
                Env: process.environment,
                Cmd: extras.map { $0.cmd } ?? ([process.executable] + process.arguments),
                Healthcheck: health,
                Image: image(container),
                Volumes: volumes.isEmpty ? nil : volumes,
                WorkingDir: process.workingDirectory,
                Entrypoint: extras?.entrypoint,
                Labels: labels(container),
                StopSignal: configuration.stopSignal),
            NetworkSettings: DockerNetworkSettings(
                Bridge: "",
                SandboxID: "",
                SandboxKey: "",
                Ports: ports,
                Gateway: bridge?.Gateway ?? "",
                IPAddress: bridge?.IPAddress ?? "",
                IPPrefixLen: bridge?.IPPrefixLen ?? 0,
                MacAddress: bridge?.MacAddress ?? "",
                Networks: networks))
    }
}
