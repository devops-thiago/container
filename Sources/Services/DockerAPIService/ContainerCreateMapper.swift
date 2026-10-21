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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

/// What a create needs from the image: its identity and the defaults its config gives the
/// container. Read by the engine side before the create is mapped.
public struct DockerImageDefaults: Sendable {
    public var description: ImageDescription
    /// The image's ID: the digest of its config for `platform`.
    public var id: String
    public var platform: ContainerizationOCI.Platform
    public var user: String?
    public var env: [String]?
    public var entrypoint: [String]?
    public var cmd: [String]?
    public var workingDir: String?
    public var labels: [String: String]?
    public var stopSignal: String?
    public var healthCheck: HealthCheckConfiguration?

    public init(
        description: ImageDescription, id: String, platform: ContainerizationOCI.Platform, user: String? = nil, env: [String]? = nil,
        entrypoint: [String]? = nil, cmd: [String]? = nil, workingDir: String? = nil, labels: [String: String]? = nil, stopSignal: String? = nil,
        healthCheck: HealthCheckConfiguration? = nil
    ) {
        self.description = description
        self.id = id
        self.platform = platform
        self.user = user
        self.env = env
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.workingDir = workingDir
        self.labels = labels
        self.stopSignal = stopSignal
        self.healthCheck = healthCheck
    }
}

/// What the engine's configuration gives a container the client said nothing about.
public struct DockerCreateDefaults: Sendable {
    public var cpus: Int
    public var memoryInBytes: UInt64
    public var dnsDomain: String?
    /// The engine's default network, which Docker calls `bridge`.
    public var builtinNetwork: String?
    /// The host's architecture as OCI names it; an `amd64` image on an `arm64` host runs
    /// under Rosetta.
    public var hostArchitecture: String
    /// The socket this service serves, which a bind of the host's Docker socket mounts.
    public var dockerSocket: String

    public init(
        cpus: Int, memoryInBytes: UInt64, dnsDomain: String? = nil, builtinNetwork: String?, hostArchitecture: String = "arm64",
        dockerSocket: String
    ) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.dnsDomain = dnsDomain
        self.builtinNetwork = builtinNetwork
        self.hostArchitecture = hostArchitecture
        self.dockerSocket = dockerSocket
    }
}

/// A named volume a create mounts, which the engine side finds or makes before the create.
public struct DockerVolumeRequest: Sendable, Equatable {
    public var name: String
    public var destination: String
    public var readOnly: Bool
    /// Made for this container alone, by `-v /path` or the image: `DELETE ?v=1` removes it.
    public var anonymous: Bool

    public init(name: String, destination: String, readOnly: Bool = false, anonymous: Bool = false) {
        self.name = name
        self.destination = destination
        self.readOnly = readOnly
        self.anonymous = anonymous
    }
}

/// A Docker create, mapped onto the engine.
public struct DockerCreatePlan: Sendable {
    /// The configuration without `volumes`, which the engine side resolves into mounts.
    public var configuration: ContainerConfiguration
    public var autoRemove: Bool
    public var volumes: [DockerVolumeRequest]
    public var extras: DockerContainerExtras
    /// What the client asked for that is not done, in the words the CLI prints after "WARNING:".
    public var warnings: [String]
}

/// Maps a Docker create body onto a `ContainerConfiguration`.
///
/// The image's config is merged in as dockerd merges it: an `Entrypoint` replaces the image's
/// entrypoint and command both, a `Cmd` replaces the image's command, `Env` adds to the image's
/// by key, labels add to the image's, and `User`, `WorkingDir`, `StopSignal` and each health
/// check field fall back to the image's when not given. A field the engine cannot honour is
/// either refused (a network mode it has no counterpart for) or reported back as a warning, and
/// only when it was given a value: the CLI sends most fields on every create, zero-valued.
public enum ContainerCreateMapper {
    /// Docker's minimum memory limit.
    public static let minimumMemory: Int64 = 6 * 1024 * 1024
    /// The most port mappings one container may publish, as the engine's own create allows.
    public static let publishedPortLimit = 64

    public static func plan(
        _ body: DockerContainerCreateBody,
        reservation: DockerIdentityReservation,
        image: DockerImageDefaults,
        imageReference: String,
        defaults: DockerCreateDefaults,
        allocatePort: () throws -> UInt16,
        newVolumeName: () -> String
    ) throws(DockerAPIError) -> DockerCreatePlan {
        let config = body.config
        let host = body.hostConfig
        var warnings: [String] = []

        let networkMode = try networkMode(host.NetworkMode)

        // The command, by dockerd's merge.
        var entrypoint = config.Entrypoint
        var cmd = config.Cmd
        if entrypoint?.isEmpty ?? true {
            if cmd?.isEmpty ?? true { cmd = image.cmd }
            if entrypoint == nil { entrypoint = image.entrypoint }
        }
        if entrypoint == [""] { entrypoint = nil }
        let argv = (entrypoint ?? []) + (cmd ?? [])
        guard let executable = argv.first else {
            throw .badRequest("no command specified")
        }

        let user = nonEmpty(config.User) ?? nonEmpty(image.user)
        let process = ProcessConfiguration(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            environment: try environment(config.Env ?? [], image: image.env ?? []),
            workingDirectory: nonEmpty(config.WorkingDir) ?? nonEmpty(image.workingDir) ?? "/",
            terminal: config.Tty ?? false,
            user: user.map { .raw(userString: $0) } ?? .id(uid: 0, gid: 0))

        var configuration = ContainerConfiguration(id: reservation.engineID, image: image.description, process: process)
        configuration.platform = image.platform
        configuration.rosetta = defaults.hostArchitecture == "arm64" && image.platform.architecture == "amd64"

        // Labels: the client's, then the image's under keys the client left alone, then this
        // service's own.
        var labels = config.Labels ?? [:]
        if let reserved = labels.keys.sorted().first(where: DockerLabels.isReserved) {
            throw .badRequest("the label \(reserved) is reserved")
        }
        for (key, value) in image.labels ?? [:] where labels[key] == nil && !DockerLabels.isReserved(key) {
            labels[key] = value
        }
        labels[DockerLabels.id] = reservation.dockerID
        labels[DockerLabels.name] = reservation.name
        labels[DockerLabels.image] = imageReference
        labels[DockerLabels.imageID] = image.id
        configuration.labels = labels

        configuration.resources = try resources(host, defaults: defaults)

        // Mounts.
        var mounts = Mounts(dockerSocket: defaults.dockerSocket)
        for bind in host.Binds ?? [] {
            try mounts.addBind(bind)
        }
        for mount in host.Mounts ?? [] {
            try mounts.add(mount, newVolumeName: newVolumeName)
        }
        for (destination, options) in (host.Tmpfs ?? [:]).sorted(by: { $0.key < $1.key }) {
            try mounts.addTmpfs(destination: destination, options: options.split(separator: ",").map(String.init))
        }
        let declaredVolumes = (config.Volumes ?? [:]).keys.sorted()
        for destination in declaredVolumes where !mounts.destinations.contains(destination) {
            try mounts.addVolume(DockerVolumeRequest(name: newVolumeName(), destination: destination, anonymous: true))
        }
        configuration.mounts = mounts.filesystems

        // Ports.
        let ports = try publishedPorts(host, exposed: (config.ExposedPorts ?? [:]).keys.sorted(), allocatePort: allocatePort)
        configuration.publishedPorts = ports

        configuration.restartPolicy = try restartPolicy(host.RestartPolicy)
        if host.AutoRemove == true, let policy = configuration.restartPolicy, policy != .no {
            throw .badRequest("can't create 'AutoRemove' container with restart policy")
        }

        configuration.healthCheck = try healthCheck(config.Healthcheck, image: image.healthCheck)

        configuration.networks = try attachments(
            networkMode: networkMode, endpoints: body.networkingConfig.EndpointsConfig ?? [:], engineID: reservation.engineID,
            name: reservation.name, defaults: defaults)
        configuration.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: host.Dns ?? [],
            domain: nonEmpty(config.Domainname) ?? defaults.dnsDomain,
            searchDomains: host.DnsSearch ?? [],
            options: host.DnsOptions ?? [])
        configuration.extraHosts = try (host.ExtraHosts ?? []).map(extraHost)

        if let hostname = nonEmpty(config.Hostname) {
            guard hostname.wholeMatch(of: #/[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?/#) != nil else {
                throw .badRequest("invalid hostname '\(hostname)': must be a DNS label of letters, digits and hyphens, up to 63 characters")
            }
            configuration.hostname = hostname
        }
        configuration.sysctls = host.Sysctls ?? [:]
        configuration.readOnly = host.ReadonlyRootfs ?? false
        configuration.useInit = host.Init ?? false
        configuration.capAdd = (host.CapAdd ?? []).map(capability)
        configuration.capDrop = (host.CapDrop ?? []).map(capability)
        if let shm = host.ShmSize, shm != 0 {
            guard shm > 0 else { throw .badRequest("SHM size can not be less than 0") }
            configuration.shmSize = UInt64(shm)
        }
        configuration.stopSignal = nonEmpty(config.StopSignal) ?? nonEmpty(image.stopSignal)

        warnings += ignored(host)
        warnings += DockerEndpointIPAMConfig.ignoredAddressWarnings(
            (body.networkingConfig.EndpointsConfig ?? [:]).sorted(by: { $0.key < $1.key }).map { $0.value?.IPAMConfig })

        let extras = DockerContainerExtras(
            image: imageReference,
            imageID: image.id,
            entrypoint: entrypoint,
            cmd: cmd,
            attachStdin: config.AttachStdin ?? false,
            attachStdout: config.AttachStdout ?? false,
            attachStderr: config.AttachStderr ?? false,
            openStdin: config.OpenStdin ?? false,
            stdinOnce: config.StdinOnce ?? false,
            exposedPorts: Set((config.ExposedPorts ?? [:]).keys).union((host.PortBindings ?? [:]).keys).sorted(),
            volumes: declaredVolumes,
            networkMode: networkMode ?? "bridge",
            autoRemove: host.AutoRemove ?? false,
            publishAllPorts: host.PublishAllPorts ?? false,
            domainname: config.Domainname ?? "",
            anonymousVolumes: mounts.volumes.filter(\.anonymous).map(\.name))
        return DockerCreatePlan(
            configuration: configuration, autoRemove: host.AutoRemove ?? false, volumes: mounts.volumes, extras: extras, warnings: warnings)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The network a mode names, nil for the default one. Modes that share another namespace
    /// have nothing to share here: each container is its own VM.
    static func networkMode(_ mode: String?) throws(DockerAPIError) -> String? {
        let mode = mode ?? ""
        switch mode {
        case "", "default", "bridge":
            return nil
        case "host", "none":
            throw .badRequest("network mode \"\(mode)\" is not supported: each container runs in its own virtual machine")
        default:
            if mode.hasPrefix("container:") {
                throw .badRequest("network mode \"container:\" is not supported: each container runs in its own virtual machine")
            }
            return mode
        }
    }

    /// The client's environment with the image's added under the keys it does not set.
    static func environment(_ user: [String], image: [String]) throws(DockerAPIError) -> [String] {
        func key(_ entry: String) -> Substring { entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0] }
        for entry in user where key(entry).isEmpty {
            throw .badRequest("invalid environment variable: \(entry)")
        }
        let keys = Set(user.map(key))
        return user + image.filter { !keys.contains(key($0)) }
    }

    /// - Parameter hostCPUs: the CPUs there are, which dockerd counts with `runtime.NumCPU()`
    ///   and the runtime gives a VM at most.
    static func resources(
        _ host: DockerHostConfig, defaults: DockerCreateDefaults, hostCPUs: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws(DockerAPIError) -> ContainerConfiguration.Resources {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = defaults.cpus
        resources.memoryInBytes = defaults.memoryInBytes
        let nanoCPUs = host.NanoCpus ?? 0
        let cpuCount = host.CpuCount ?? 0
        guard nanoCPUs >= 0, cpuCount >= 0 else {
            throw .badRequest("invalid CPU count: it cannot be negative")
        }
        if nanoCPUs > 0 && cpuCount > 0 {
            throw .badRequest("Conflicting options: CPU count and NanoCPUs cannot both be set")
        }
        // dockerd refuses more CPUs than there are, in these words (moby daemon_unix.go,
        // verifyPlatformContainerResources). The runtime would give the VM no more than the
        // host's anyway, and far more overflows its CPU quota (`cpus * 100_000`). dockerd only
        // has the NanoCPUs check; CpuCount is the same quantity here, so it gets the same one.
        guard nanoCPUs <= Int64(hostCPUs) * 1_000_000_000, cpuCount <= Int64(hostCPUs) else {
            throw .badRequest("range of CPUs is from 0.01 to \(hostCPUs).00, as there are only \(hostCPUs) CPUs available")
        }
        if nanoCPUs > 0 {
            // A VM has whole CPUs: a fraction is rounded up, so the container gets at least
            // what it asked for.
            resources.cpus = Int((nanoCPUs + 999_999_999) / 1_000_000_000)
        } else if cpuCount > 0 {
            resources.cpus = Int(cpuCount)
        }
        if let memory = host.Memory, memory != 0 {
            guard memory >= minimumMemory else {
                throw .badRequest("Minimum memory limit allowed is 6MB")
            }
            resources.memoryInBytes = UInt64(memory)
        }
        return resources
    }

    /// The mounts of a create, in the order given, refusing a destination given twice.
    struct Mounts {
        /// What a bind of the host's Docker socket mounts: this service's own, as Docker
        /// Desktop mounts its engine's. Never the host's, which may be another engine's.
        var dockerSocket: String
        var filesystems: [Filesystem] = []
        var volumes: [DockerVolumeRequest] = []
        var destinations: Set<String> = []

        func bindSource(_ source: String) -> String {
            DockerHostSocket.bindSource(for: source, enginePath: dockerSocket)
        }

        mutating func claim(_ destination: String) throws(DockerAPIError) {
            guard destination.hasPrefix("/") else {
                throw .badRequest("invalid mount config: mount path must be absolute: \(destination)")
            }
            guard destinations.insert(destination).inserted else {
                throw .badRequest("Duplicate mount point: \(destination)")
            }
        }

        /// `-v source:destination[:options]`: a host folder when the source is a path, a named
        /// volume otherwise.
        mutating func addBind(_ spec: String) throws(DockerAPIError) {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw .badRequest("invalid volume specification: '\(spec)'")
            }
            var readOnly = false
            for option in parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : [] {
                switch option {
                case "ro": readOnly = true
                case "rw": readOnly = false
                // SELinux relabelling, propagation, copy and consistency modes mean nothing to
                // a folder shared into a VM.
                case "z", "Z", "nocopy", "consistent", "cached", "delegated", "private", "rprivate", "shared", "rshared", "slave", "rslave":
                    continue
                default:
                    throw .badRequest("invalid mode: \(option)")
                }
            }
            let (source, destination) = (parts[0], parts[1])
            if source.hasPrefix("/") {
                try claim(destination)
                filesystems.append(.virtiofs(source: bindSource(source), destination: destination, options: readOnly ? ["ro"] : []))
            } else {
                try addVolume(DockerVolumeRequest(name: source, destination: destination, readOnly: readOnly))
            }
        }

        mutating func add(_ mount: DockerMount, newVolumeName: () -> String) throws(DockerAPIError) {
            let destination = mount.Target ?? ""
            let readOnly = mount.ReadOnly ?? false
            switch mount.type ?? "" {
            case "bind":
                guard let source = mount.Source, source.hasPrefix("/") else {
                    throw .badRequest("invalid mount config for type \"bind\": invalid mount path: '\(mount.Source ?? "")' mount path must be absolute")
                }
                try claim(destination)
                filesystems.append(.virtiofs(source: bindSource(source), destination: destination, options: readOnly ? ["ro"] : []))
            case "volume":
                if let source = mount.Source, !source.isEmpty {
                    try addVolume(DockerVolumeRequest(name: source, destination: destination, readOnly: readOnly))
                } else {
                    try addVolume(DockerVolumeRequest(name: newVolumeName(), destination: destination, readOnly: readOnly, anonymous: true))
                }
            case "tmpfs":
                var options: [String] = []
                if let size = mount.TmpfsOptions?.SizeBytes, size > 0 { options.append("size=\(size)") }
                if let mode = mount.TmpfsOptions?.Mode, mode != 0 { options.append("mode=\(String(mode, radix: 8))") }
                try addTmpfs(destination: destination, options: options)
            case let other:
                throw .badRequest("mount type \"\(other)\" is not supported")
            }
        }

        mutating func addTmpfs(destination: String, options: [String]) throws(DockerAPIError) {
            try claim(destination)
            filesystems.append(.tmpfs(destination: destination, options: options))
        }

        mutating func addVolume(_ volume: DockerVolumeRequest) throws(DockerAPIError) {
            guard volume.name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_.-]*/#) != nil else {
                throw .badRequest(
                    "create \(volume.name): \"\(volume.name)\" includes invalid characters for a local volume name, only \"[a-zA-Z0-9][a-zA-Z0-9_.-]\" are allowed. If you intended to pass a host directory, use absolute path"
                )
            }
            try claim(volume.destination)
            volumes.append(volume)
        }
    }

    /// `PortBindings`, plus every exposed port when `PublishAllPorts` is set. An empty or zero
    /// host port takes a free one, as dockerd does.
    static func publishedPorts(_ host: DockerHostConfig, exposed: [String], allocatePort: () throws -> UInt16) throws(DockerAPIError) -> [PublishPort] {
        var bindings = (host.PortBindings ?? [:]).mapValues { $0 ?? [] }
        if host.PublishAllPorts == true {
            for port in exposed where (bindings[port] ?? []).isEmpty {
                bindings[port] = [DockerPortBinding()]
            }
        }
        var ports: [PublishPort] = []
        for (key, list) in bindings.sorted(by: { $0.key < $1.key }) {
            let (containerPort, proto) = try portKey(key)
            for binding in list {
                let address: IPAddress
                do {
                    address = try IPAddress(nonEmpty(binding.HostIp) ?? "0.0.0.0")
                } catch {
                    throw .badRequest("invalid host IP address: \(binding.HostIp ?? "")")
                }
                let hostPort: UInt16
                let text = binding.HostPort ?? ""
                if text.isEmpty || text == "0" {
                    do {
                        hostPort = try allocatePort()
                    } catch {
                        throw .internalError("no free host port for \(key): \(error)")
                    }
                } else if let port = validHostPort(text) {
                    hostPort = port
                } else {
                    throw .badRequest("invalid host port: \(text)")
                }
                do {
                    ports.append(try PublishPort(hostAddress: address, hostPort: hostPort, containerPort: containerPort, proto: proto, count: 1))
                } catch {
                    throw .badRequest("invalid port mapping \(text):\(key): \(error)")
                }
            }
        }
        guard ports.count <= publishedPortLimit else {
            throw .badRequest("cannot publish more than \(publishedPortLimit) ports")
        }
        guard !ports.hasOverlaps() else {
            throw .badRequest("host ports for different port mappings may not overlap")
        }
        return ports
    }

    /// A single port or the first port of a valid inclusive range, matching existing behavior.
    private static func validHostPort(_ text: String) -> UInt16? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = UInt16(parts[0]), first > 0 else { return nil }
        if parts.count == 2 {
            guard let last = UInt16(parts[1]), last >= first else { return nil }
        }
        return first
    }

    /// `80/tcp`, `53/udp`, or `80` meaning tcp.
    static func portKey(_ key: String) throws(DockerAPIError) -> (UInt16, PublishProtocol) {
        let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let port = UInt16(parts[0]), port > 0 else {
            throw .badRequest("invalid port specification: \"\(key)\"")
        }
        guard parts.count == 2 else { return (port, .tcp) }
        guard let proto = PublishProtocol(String(parts[1])) else {
            throw .badRequest("invalid proto: \(parts[1])")
        }
        return (port, proto)
    }

    static func restartPolicy(_ policy: DockerRestartPolicy?) throws(DockerAPIError) -> ContainerConfiguration.RestartPolicy? {
        let name = policy?.Name ?? ""
        let retries = policy?.MaximumRetryCount ?? 0
        switch name {
        case "":
            return nil
        case "no", "always", "unless-stopped":
            guard retries == 0 else {
                throw .badRequest(
                    "invalid restart policy: maximum retry count can only be used with 'on-failure'" + (retries < 0 ? " and cannot be negative" : ""))
            }
            return name == "no" ? nil : ContainerConfiguration.RestartPolicy(name)
        case "on-failure":
            guard retries >= 0 else {
                throw .badRequest("invalid restart policy: maximum retry count cannot be negative")
            }
            return .onFailure(maxRetries: retries > 0 ? retries : nil)
        default:
            throw .badRequest("invalid restart policy: unknown policy '\(name)'; use one of 'no', 'always', 'on-failure', or 'unless-stopped'")
        }
    }

    /// The client's check over the image's, field by field, as the engine settles one.
    static func healthCheck(_ user: DockerHealthConfig?, image: HealthCheckConfiguration?) throws(DockerAPIError) -> HealthCheckConfiguration? {
        let mapped = user.map {
            HealthCheckConfiguration(
                test: $0.Test ?? [], interval: $0.Interval ?? 0, timeout: $0.Timeout ?? 0, startPeriod: $0.StartPeriod ?? 0,
                startInterval: $0.StartInterval ?? 0, retries: $0.Retries ?? 0)
        }
        if let mapped {
            do {
                try mapped.validate()
            } catch {
                throw .badRequest("\(error)")
            }
        }
        return HealthCheckConfiguration.resolve(user: mapped, image: mapped?.disables == true ? nil : image)
    }

    /// The default network unless the mode names another, then every other network the client
    /// listed. On a network of its own, a container also answers to its name, as on Docker's
    /// user-defined networks. An address asked for (`docker run --ip`) is not given: the
    /// network assigns one, and `create` warns that it was ignored.
    static func attachments(
        networkMode: String?, endpoints: [String: DockerEndpointSettings?], engineID: String, name: String, defaults: DockerCreateDefaults
    ) throws(DockerAPIError) -> [AttachmentConfiguration] {
        func engineNetwork(_ docker: String) throws(DockerAPIError) -> String {
            guard ["bridge", "default"].contains(docker) else { return docker }
            guard let builtin = defaults.builtinNetwork else {
                throw .internalError("the engine has no default network")
            }
            return builtin
        }
        var order: [String] = [try engineNetwork(networkMode ?? "bridge")]
        var aliases: [String: [String]] = [:]
        for (docker, settings) in endpoints.sorted(by: { $0.key < $1.key }) {
            let network = try engineNetwork(docker)
            if !order.contains(network) { order.append(network) }
            aliases[network, default: []] += settings?.Aliases ?? []
        }
        let fqdn = defaults.dnsDomain.map { "\(engineID).\($0)." } ?? engineID
        let nameIsAlias = name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            $0.wholeMatch(of: #/[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?/#) != nil
        }
        return order.enumerated().map { index, network in
            var names = aliases[network] ?? []
            if network != defaults.builtinNetwork && nameIsAlias { names.append(name) }
            var seen = Set<String>()
            names = names.filter { seen.insert($0).inserted }
            return AttachmentConfiguration(
                network: network, options: AttachmentOptions(hostname: index == 0 ? fqdn : engineID, mtu: 1280, aliases: names))
        }
    }

    /// `name:address` or `name=address`, the address an IP literal or `host-gateway`.
    static func extraHost(_ entry: String) throws(DockerAPIError) -> ContainerConfiguration.ExtraHost {
        let separator = entry.firstIndex(where: { $0 == "=" || $0 == ":" })
        guard let separator, separator != entry.startIndex, entry.index(after: separator) != entry.endIndex else {
            throw .badRequest("invalid IP address in add-host: \"\(entry)\"")
        }
        let name = String(entry[..<separator])
        var address = String(entry[entry.index(after: separator)...])
        if address.hasPrefix("[") && address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        guard address == ContainerConfiguration.ExtraHost.hostGateway || (try? IPAddress(address)) != nil else {
            throw .badRequest("invalid IP address in add-host: \"\(address)\"")
        }
        return ContainerConfiguration.ExtraHost(name: name, address: address)
    }

    /// `NET_ADMIN` or `cap_net_admin` as `CAP_NET_ADMIN`; `ALL` as it is.
    static func capability(_ name: String) -> String {
        let upper = name.uppercased()
        return upper == "ALL" || upper.hasPrefix("CAP_") ? upper : "CAP_" + upper
    }

    /// Warnings for the fields given a value that the engine does not act on.
    static func ignored(_ host: DockerHostConfig) -> [String] {
        var warnings: [String] = []
        func given(_ condition: Bool, _ warning: String) {
            if condition { warnings.append(warning) }
        }
        given(host.Privileged == true, "Privileged mode is not supported; the container runs unprivileged.")
        given(!(host.Devices ?? []).isEmpty, "Devices are not supported and were not added.")
        given(!(host.DeviceRequests ?? []).isEmpty, "Device requests (GPUs) are not supported and were ignored.")
        given(!(host.VolumesFrom ?? []).isEmpty, "VolumesFrom is not supported and was ignored.")
        given(!(host.Links ?? []).isEmpty, "Links are not supported and were ignored; use a network instead.")
        given(!(host.SecurityOpt ?? []).isEmpty, "Security options are not supported and were ignored.")
        given((host.CpuShares ?? 0) != 0, "CPU shares are not supported and were ignored; the container gets whole CPUs.")
        given(!(host.CpusetCpus ?? "").isEmpty, "CPU sets are not supported and were ignored.")
        given((host.MemoryReservation ?? 0) != 0, "Memory reservation is not supported and was ignored.")
        given((host.MemorySwap ?? 0) > 0, "Memory swap limits are not supported and were ignored.")
        given((host.PidsLimit ?? 0) > 0, "PIDs limits are not supported and were ignored.")
        given(host.OomKillDisable == true, "Disabling the OOM killer is not supported and was ignored.")
        given(!(host.Ulimits ?? []).isEmpty, "Ulimits are not supported through the Docker API yet and were ignored.")
        given(!(host.GroupAdd ?? []).isEmpty, "Additional groups are not supported and were ignored.")
        for (field, value) in [("PidMode", host.PidMode), ("IpcMode", host.IpcMode), ("UTSMode", host.UTSMode), ("UsernsMode", host.UsernsMode)] {
            given(!["", "private", "shareable"].contains(value ?? ""), "\(field) \"\(value ?? "")\" is not supported and was ignored.")
        }
        let logDriver = host.LogConfig?.type ?? ""
        given(!["", "json-file", "local"].contains(logDriver), "Log driver \"\(logDriver)\" is not supported; logs are kept by the engine.")
        given(!["", "runc", "io.containerd.runc.v2"].contains(host.Runtime ?? ""), "Runtime \"\(host.Runtime ?? "")\" is not supported and was ignored.")
        return warnings
    }
}
