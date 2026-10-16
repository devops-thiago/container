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

// The container shapes of Docker Engine API 1.48, with Docker's field names, holding only what
// the container routes read or answer. A field the client sends that is not here is ignored by
// the decoder; the create mapper warns about the ones that would change what runs.

/// `{}`: the value of a set member in Docker's JSON (`ExposedPorts`, `Volumes`).
public struct DockerEmptyObject: Codable, Sendable, Equatable {
    public init() {}
}

/// Any JSON value, read and dropped: for fields whose presence matters but whose shape does not.
public struct DockerIgnoredValue: Decodable, Sendable {
    public init(from decoder: any Decoder) throws {}
}

/// `Config.Healthcheck`: durations in nanoseconds, zero meaning "inherit".
public struct DockerHealthConfig: Codable, Sendable, Equatable {
    public var Test: [String]?
    public var Interval: Int64?
    public var Timeout: Int64?
    public var StartPeriod: Int64?
    public var StartInterval: Int64?
    public var Retries: Int?

    public init(
        Test: [String]? = nil, Interval: Int64? = nil, Timeout: Int64? = nil, StartPeriod: Int64? = nil, StartInterval: Int64? = nil,
        Retries: Int? = nil
    ) {
        self.Test = Test
        self.Interval = Interval
        self.Timeout = Timeout
        self.StartPeriod = StartPeriod
        self.StartInterval = StartInterval
        self.Retries = Retries
    }
}

/// `Config`: what runs, as the create body carries it at its top level and inspect echoes it.
public struct DockerContainerConfig: Codable, Sendable {
    public var Hostname: String?
    public var Domainname: String?
    public var User: String?
    public var AttachStdin: Bool?
    public var AttachStdout: Bool?
    public var AttachStderr: Bool?
    public var ExposedPorts: [String: DockerEmptyObject]?
    public var Tty: Bool?
    public var OpenStdin: Bool?
    public var StdinOnce: Bool?
    public var Env: [String]?
    /// Nil when not given, `[]` when given empty: Docker's merge tells them apart.
    public var Cmd: [String]?
    public var Healthcheck: DockerHealthConfig?
    public var Image: String?
    public var Volumes: [String: DockerEmptyObject]?
    public var WorkingDir: String?
    /// Nil when not given, `[]` or `[""]` when cleared.
    public var Entrypoint: [String]?
    public var Labels: [String: String]?
    public var StopSignal: String?
    public var StopTimeout: Int?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case Hostname, Domainname, User, AttachStdin, AttachStdout, AttachStderr, ExposedPorts, Tty, OpenStdin, StdinOnce, Env, Cmd
        case Healthcheck, Image, Volumes, WorkingDir, Entrypoint, Labels, StopSignal, StopTimeout
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Hostname = try c.decodeIfPresent(String.self, forKey: .Hostname)
        Domainname = try c.decodeIfPresent(String.self, forKey: .Domainname)
        User = try c.decodeIfPresent(String.self, forKey: .User)
        AttachStdin = try c.decodeIfPresent(Bool.self, forKey: .AttachStdin)
        AttachStdout = try c.decodeIfPresent(Bool.self, forKey: .AttachStdout)
        AttachStderr = try c.decodeIfPresent(Bool.self, forKey: .AttachStderr)
        ExposedPorts = try c.decodeIfPresent([String: DockerEmptyObject].self, forKey: .ExposedPorts)
        Tty = try c.decodeIfPresent(Bool.self, forKey: .Tty)
        OpenStdin = try c.decodeIfPresent(Bool.self, forKey: .OpenStdin)
        StdinOnce = try c.decodeIfPresent(Bool.self, forKey: .StdinOnce)
        Env = try c.decodeIfPresent([String].self, forKey: .Env)
        Cmd = try Self.stringList(c, .Cmd)
        Healthcheck = try c.decodeIfPresent(DockerHealthConfig.self, forKey: .Healthcheck)
        Image = try c.decodeIfPresent(String.self, forKey: .Image)
        Volumes = try c.decodeIfPresent([String: DockerEmptyObject].self, forKey: .Volumes)
        WorkingDir = try c.decodeIfPresent(String.self, forKey: .WorkingDir)
        Entrypoint = try Self.stringList(c, .Entrypoint)
        Labels = try c.decodeIfPresent([String: String].self, forKey: .Labels)
        StopSignal = try c.decodeIfPresent(String.self, forKey: .StopSignal)
        StopTimeout = try c.decodeIfPresent(Int.self, forKey: .StopTimeout)
    }

    /// `Cmd` and `Entrypoint` are lists, but dockerd also takes a single string for either, the
    /// way older clients sent them.
    private static func stringList(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String]? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key) {
            return [text]
        }
        return try c.decodeIfPresent([String].self, forKey: key)
    }
}

/// One `HostConfig.PortBindings` entry. An empty `HostPort` asks for any free port.
public struct DockerPortBinding: Codable, Sendable, Equatable {
    public var HostIp: String?
    public var HostPort: String?

    public init(HostIp: String? = nil, HostPort: String? = nil) {
        self.HostIp = HostIp
        self.HostPort = HostPort
    }
}

/// `HostConfig.RestartPolicy`.
public struct DockerRestartPolicy: Codable, Sendable, Equatable {
    public var Name: String?
    public var MaximumRetryCount: Int?

    public init(Name: String? = nil, MaximumRetryCount: Int? = nil) {
        self.Name = Name
        self.MaximumRetryCount = MaximumRetryCount
    }
}

/// One `HostConfig.Mounts` entry, `--mount` as the CLI sends it.
public struct DockerMount: Codable, Sendable, Equatable {
    public struct TmpfsOptions: Codable, Sendable, Equatable {
        public var SizeBytes: Int64?
        public var Mode: UInt32?

        public init(SizeBytes: Int64? = nil, Mode: UInt32? = nil) {
            self.SizeBytes = SizeBytes
            self.Mode = Mode
        }
    }

    public var type: String?
    public var Source: String?
    public var Target: String?
    public var ReadOnly: Bool?
    public var TmpfsOptions: TmpfsOptions?

    public init(type: String? = nil, Source: String? = nil, Target: String? = nil, ReadOnly: Bool? = nil, TmpfsOptions: TmpfsOptions? = nil) {
        self.type = type
        self.Source = Source
        self.Target = Target
        self.ReadOnly = ReadOnly
        self.TmpfsOptions = TmpfsOptions
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case Source, Target, ReadOnly, TmpfsOptions
    }
}

/// `HostConfig.LogConfig`.
public struct DockerLogConfig: Codable, Sendable, Equatable {
    public var type: String?

    public init(type: String? = nil) {
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case type = "Type"
    }
}

/// `HostConfig`: how the container is placed on the host. The first group maps onto the engine;
/// the second is read only so that a value that would change what runs is warned about rather
/// than dropped without a word.
public struct DockerHostConfig: Decodable, Sendable {
    public var Binds: [String]?
    public var Mounts: [DockerMount]?
    public var Tmpfs: [String: String]?
    public var PortBindings: [String: [DockerPortBinding]?]?
    public var PublishAllPorts: Bool?
    public var AutoRemove: Bool?
    public var RestartPolicy: DockerRestartPolicy?
    public var NanoCpus: Int64?
    public var CpuCount: Int64?
    public var Memory: Int64?
    public var ShmSize: Int64?
    public var ReadonlyRootfs: Bool?
    public var Init: Bool?
    public var CapAdd: [String]?
    public var CapDrop: [String]?
    public var Dns: [String]?
    public var DnsSearch: [String]?
    public var DnsOptions: [String]?
    public var ExtraHosts: [String]?
    public var NetworkMode: String?
    public var Sysctls: [String: String]?

    public var Privileged: Bool?
    public var Devices: [DockerIgnoredValue]?
    public var DeviceRequests: [DockerIgnoredValue]?
    public var VolumesFrom: [String]?
    public var Links: [String]?
    public var SecurityOpt: [String]?
    public var CpuShares: Int64?
    public var CpusetCpus: String?
    public var MemoryReservation: Int64?
    public var MemorySwap: Int64?
    public var PidsLimit: Int64?
    public var PidMode: String?
    public var IpcMode: String?
    public var UTSMode: String?
    public var UsernsMode: String?
    public var Ulimits: [DockerIgnoredValue]?
    public var LogConfig: DockerLogConfig?
    public var OomKillDisable: Bool?
    public var GroupAdd: [String]?
    public var Runtime: String?

    public init() {}
}

/// An endpoint's `IPAMConfig`: the addresses a client asks a network for. The Docker CLI sends
/// `docker network connect`'s with no address in it as `{}`, and other clients may send the
/// fields empty, so only an address in it is a request for one, as in dockerd.
public struct DockerEndpointIPAMConfig: Codable, Sendable, Equatable {
    public var IPv4Address: String?
    public var IPv6Address: String?
    public var LinkLocalIPs: [String]?

    public init(IPv4Address: String? = nil, IPv6Address: String? = nil, LinkLocalIPs: [String]? = nil) {
        self.IPv4Address = IPv4Address
        self.IPv6Address = IPv6Address
        self.LinkLocalIPs = LinkLocalIPs
    }

    static let notSupported = "a static address is not supported by SiliconShip: the network assigns one"

    /// The fields that name an address.
    public var requestedFields: [String] {
        var fields: [String] = []
        if !(IPv4Address ?? "").isEmpty { fields.append("IPv4Address") }
        if !(IPv6Address ?? "").isEmpty { fields.append("IPv6Address") }
        if (LinkLocalIPs ?? []).contains(where: { !$0.isEmpty }) { fields.append("LinkLocalIPs") }
        return fields
    }

    /// Whether it names any address.
    public var requestsAddress: Bool { !requestedFields.isEmpty }

    /// Refuses a request for an address, for `network connect`, whose answer has no warnings
    /// to say it was ignored in: the engine's network assigns every address.
    public static func refuseAddress(_ config: DockerEndpointIPAMConfig?) throws(DockerAPIError) {
        if config?.requestsAddress == true {
            throw .badRequest(notSupported)
        }
    }

    /// A warning for each field that names an address, for a create, which runs the container
    /// with the network's own address rather than failing a compose file that pins one.
    public static func ignoredAddressWarnings(_ configs: [DockerEndpointIPAMConfig?]) -> [String] {
        var fields: [String] = []
        for field in configs.flatMap({ $0?.requestedFields ?? [] }) where !fields.contains(field) {
            fields.append(field)
        }
        return fields.map { "\(notSupported); \($0) was ignored" }
    }
}

/// `NetworkingConfig.EndpointsConfig` values: the aliases are read, and an address asked for
/// is warned about and ignored.
public struct DockerEndpointSettings: Codable, Sendable, Equatable {
    public var Aliases: [String]?
    public var IPAMConfig: DockerEndpointIPAMConfig?

    public init(Aliases: [String]? = nil, IPAMConfig: DockerEndpointIPAMConfig? = nil) {
        self.Aliases = Aliases
        self.IPAMConfig = IPAMConfig
    }
}

public struct DockerNetworkingConfig: Decodable, Sendable {
    public var EndpointsConfig: [String: DockerEndpointSettings?]?

    public init(EndpointsConfig: [String: DockerEndpointSettings?]? = nil) {
        self.EndpointsConfig = EndpointsConfig
    }
}

/// The body of `POST /containers/create`: `Config` at the top level, with `HostConfig` and
/// `NetworkingConfig` beside its fields.
public struct DockerContainerCreateBody: Decodable, Sendable {
    public var config: DockerContainerConfig
    public var hostConfig: DockerHostConfig
    public var networkingConfig: DockerNetworkingConfig

    public init(config: DockerContainerConfig = .init(), hostConfig: DockerHostConfig = .init(), networkingConfig: DockerNetworkingConfig = .init()) {
        self.config = config
        self.hostConfig = hostConfig
        self.networkingConfig = networkingConfig
    }

    enum CodingKeys: String, CodingKey {
        case HostConfig, NetworkingConfig
    }

    public init(from decoder: any Decoder) throws {
        config = try DockerContainerConfig(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostConfig = try c.decodeIfPresent(DockerHostConfig.self, forKey: .HostConfig) ?? .init()
        networkingConfig = try c.decodeIfPresent(DockerNetworkingConfig.self, forKey: .NetworkingConfig) ?? .init()
    }
}

/// The answer to `POST /containers/create`.
public struct DockerContainerCreateResponse: Codable, Sendable, Equatable {
    public var Id: String
    public var Warnings: [String]
}

/// The answer to `POST /containers/prune`.
public struct DockerContainerPruneResponse: Codable, Sendable, Equatable {
    public var ContainersDeleted: [String]?
    public var SpaceReclaimed: Int64
}

/// One published port, as `GET /containers/json` lists it.
public struct DockerPort: Codable, Sendable, Equatable {
    public var IP: String?
    public var PrivatePort: Int
    public var PublicPort: Int?
    public var type: String

    enum CodingKeys: String, CodingKey {
        case IP, PrivatePort, PublicPort
        case type = "Type"
    }
}

/// One mount, as list and inspect show it.
public struct DockerMountPoint: Codable, Sendable, Equatable {
    public var type: String
    public var Name: String?
    public var Source: String
    public var Destination: String
    public var Driver: String?
    public var Mode: String
    public var RW: Bool
    public var Propagation: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case Name, Source, Destination, Driver, Mode, RW, Propagation
    }
}

/// One network a container is on, as list and inspect show it.
public struct DockerEndpoint: Codable, Sendable, Equatable {
    public var Aliases: [String]?
    public var NetworkID: String
    public var EndpointID: String
    public var Gateway: String
    public var IPAddress: String
    public var IPPrefixLen: Int
    public var IPv6Gateway: String
    public var GlobalIPv6Address: String
    public var GlobalIPv6PrefixLen: Int
    public var MacAddress: String
    public var DNSNames: [String]?
}

/// One entry of `GET /containers/json`.
public struct DockerContainerSummary: Codable, Sendable, Equatable {
    public struct HostConfigSummary: Codable, Sendable, Equatable {
        public var NetworkMode: String
    }
    public struct NetworkSettingsSummary: Codable, Sendable, Equatable {
        public var Networks: [String: DockerEndpoint]
    }

    public var Id: String
    public var Names: [String]
    public var Image: String
    public var ImageID: String
    public var Command: String
    public var Created: Int64
    public var Ports: [DockerPort]
    public var Labels: [String: String]
    public var State: String
    public var Status: String
    public var HostConfig: HostConfigSummary
    public var NetworkSettings: NetworkSettingsSummary
    public var Mounts: [DockerMountPoint]
    /// With `size=1`, and in `GET /system/df`: what the container wrote to its root
    /// filesystem. Left out when it is zero, as dockerd leaves it out, or when the engine
    /// cannot tell.
    public var SizeRw: Int64? = nil
}

/// `State.Health`.
public struct DockerHealth: Codable, Sendable, Equatable {
    public struct LogEntry: Codable, Sendable, Equatable {
        public var Start: String
        public var End: String
        public var ExitCode: Int
        public var Output: String
    }

    public var Status: String
    public var FailingStreak: Int
    public var Log: [LogEntry]
}

/// `State` in inspect.
public struct DockerContainerState: Codable, Sendable, Equatable {
    public var Status: String
    public var Running: Bool
    public var Paused: Bool
    public var Restarting: Bool
    public var OOMKilled: Bool
    public var Dead: Bool
    public var Pid: Int
    public var ExitCode: Int
    public var Error: String
    public var StartedAt: String
    public var FinishedAt: String
    public var Health: DockerHealth?
}

/// `HostConfig` as inspect shows it, rebuilt from what the engine holds.
public struct DockerHostConfigView: Codable, Sendable, Equatable {
    public var Binds: [String]?
    public var NetworkMode: String
    public var PortBindings: [String: [DockerPortBinding]]
    public var RestartPolicy: DockerRestartPolicy
    public var AutoRemove: Bool
    public var CapAdd: [String]?
    public var CapDrop: [String]?
    public var Dns: [String]
    public var DnsOptions: [String]
    public var DnsSearch: [String]
    public var ExtraHosts: [String]?
    public var Privileged: Bool
    public var PublishAllPorts: Bool
    public var ReadonlyRootfs: Bool
    public var ShmSize: Int64
    public var Sysctls: [String: String]?
    public var Memory: Int64
    public var NanoCpus: Int64
    public var Init: Bool?
    public var LogConfig: DockerLogConfig
}

/// `Config` as inspect shows it.
public struct DockerContainerConfigView: Codable, Sendable, Equatable {
    public var Hostname: String
    public var Domainname: String
    public var User: String
    public var AttachStdin: Bool
    public var AttachStdout: Bool
    public var AttachStderr: Bool
    public var ExposedPorts: [String: DockerEmptyObject]?
    public var Tty: Bool
    public var OpenStdin: Bool
    public var StdinOnce: Bool
    public var Env: [String]
    public var Cmd: [String]?
    public var Healthcheck: DockerHealthConfig?
    public var Image: String
    public var Volumes: [String: DockerEmptyObject]?
    public var WorkingDir: String
    public var Entrypoint: [String]?
    public var Labels: [String: String]
    public var StopSignal: String?
}

/// `NetworkSettings` in inspect, with the top-level address fields the CLI's templates still read.
public struct DockerNetworkSettings: Codable, Sendable, Equatable {
    public var Bridge: String
    public var SandboxID: String
    public var SandboxKey: String
    public var Ports: [String: [DockerPortBinding]?]
    public var Gateway: String
    public var IPAddress: String
    public var IPPrefixLen: Int
    public var MacAddress: String
    public var Networks: [String: DockerEndpoint]
}

/// The answer to `GET /containers/{id}/json`.
public struct DockerContainerInspect: Codable, Sendable, Equatable {
    public var Id: String
    public var Created: String
    public var Path: String
    public var Args: [String]
    public var State: DockerContainerState
    public var Image: String
    public var ResolvConfPath: String
    public var HostnamePath: String
    public var HostsPath: String
    public var LogPath: String
    public var Name: String
    public var RestartCount: Int
    public var Driver: String
    public var Platform: String
    public var MountLabel: String
    public var ProcessLabel: String
    public var AppArmorProfile: String
    public var HostConfig: DockerHostConfigView
    public var Mounts: [DockerMountPoint]
    public var Config: DockerContainerConfigView
    public var NetworkSettings: DockerNetworkSettings
    /// With `size=1`: what the container wrote to its root filesystem, when the engine can tell.
    public var SizeRw: Int64? = nil
}
