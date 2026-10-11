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

/// A compose project as its files describe it, once they are merged, their variables are
/// substituted and their short forms are spelled out.
public struct ComposeFile: Sendable, Equatable {
    /// The top-level `name:`, when a file gives one.
    public var name: String?
    /// Every service the files define, by name. Profiles are not applied here.
    public var services: [ComposeService]
    public var networks: [ComposeNetwork]
    public var volumes: [ComposeVolume]

    public init(name: String? = nil, services: [ComposeService] = [], networks: [ComposeNetwork] = [], volumes: [ComposeVolume] = []) {
        self.name = name
        self.services = services.sorted { $0.name < $1.name }
        self.networks = networks.sorted { $0.key < $1.key }
        self.volumes = volumes.sorted { $0.key < $1.key }
    }

    public func service(_ name: String) -> ComposeService? {
        services.first { $0.name == name }
    }

    /// The parts of the project `services` come to: the services themselves, the networks
    /// they attach to and the volumes they mount.
    public func parts(of services: [ComposeService]) -> Set<ComposePart> {
        var parts = Set<ComposePart>()
        for service in services {
            parts.insert(.service(service.name))
            for key in service.networkKeys { parts.insert(.network(key)) }
            for key in service.volumeKeys { parts.insert(.volume(key)) }
        }
        return parts
    }
}

public struct ComposeService: Sendable, Equatable {
    public var name: String
    public var image: String?
    public var build: ComposeBuild?
    /// nil runs what the image runs.
    public var command: [String]?
    public var entrypoint: [String]?
    /// The service's environment: its `env_file`s, then `environment`, with names that
    /// carry no value taken from the environment compose ran in.
    public var environment: [String: String] = [:]
    public var ports: [ComposePort] = []
    public var mounts: [ComposeMount] = []
    public var dependsOn: [ComposeDependency] = []
    public var healthcheck: ComposeHealthcheck?
    public var restart: String?
    public var containerName: String?
    /// The networks the service names. Empty means the project's default network.
    public var networks: [ComposeServiceNetwork] = []
    public var profiles: [String] = []
    public var pullPolicy: ComposePullPolicy?
    public var workingDirectory: String?
    public var user: String?
    public var labels: [String: String] = [:]
    public var platform: String?
    public var tmpfs: [String] = []
    public var ulimits: [ComposeUlimit] = []
    public var capAdd: [String] = []
    public var capDrop: [String] = []
    public var readOnly = false
    public var useInit = false
    public var tty = false
    public var shmSize: String?
    public var dns: [String] = []
    public var dnsSearch: [String] = []
    public var dnsOptions: [String] = []
    public var stopSignal: String?
    /// Seconds a stop waits before it kills.
    public var stopGracePeriod: Double?
    public var cpus: Double?
    public var memory: String?
    public var sysctls: [String: String] = [:]
    public var hostname: String?
    /// `name:address` pairs, as `--add-host` takes them.
    public var extraHosts: [String] = []
    /// Where the service is defined, for messages about it.
    public var location: SourceLocation?

    public init(name: String) {
        self.name = name
    }

    /// Whether the service runs without being named: it has no profiles, or one of them is
    /// among `profiles`. `*` turns every profile on.
    public func isActive(in profiles: [String]) -> Bool {
        self.profiles.isEmpty || profiles.contains("*") || !Set(self.profiles).isDisjoint(with: profiles)
    }

    /// The keys of the networks the service attaches to: the ones it names, or the
    /// project's default.
    public var networkKeys: [String] {
        networks.isEmpty ? ["default"] : networks.map(\.key)
    }

    /// The keys of the named volumes the service mounts.
    public var volumeKeys: [String] {
        mounts.compactMap { mount in
            if case .volume(let key) = mount.kind { return key }
            return nil
        }
    }
}

public struct ComposeBuild: Sendable, Equatable {
    /// The build context: an absolute path.
    public var context: String
    /// The Dockerfile, relative to the context unless absolute. nil is the builder's default.
    public var dockerfile: String?
    public var args: [String: String] = [:]
    public var target: String?
    public var labels: [String: String] = [:]
    public var noCache = false
    public var platforms: [String] = []

    public init(context: String) {
        self.context = context
    }
}

public struct ComposePort: Sendable, Hashable {
    public enum Transport: String, Sendable { case tcp, udp }

    public var hostIP: String?
    /// The host port or range (`8080`, `8000-8010`). nil asks for any free port.
    public var published: String?
    /// The container port or range.
    public var target: String
    public var transport: Transport

    public init(hostIP: String? = nil, published: String?, target: String, transport: Transport = .tcp) {
        self.hostIP = hostIP
        self.published = published
        self.target = target
        self.transport = transport
    }
}

public struct ComposeMount: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A host directory or file, by absolute path.
        case bind(source: String)
        /// A named volume, by its key under the top-level `volumes:`.
        case volume(key: String)
        /// A volume made for this container and named by the engine.
        case anonymous
        case tmpfs(size: String?)
    }

    public var kind: Kind
    public var target: String
    public var readOnly: Bool

    public init(kind: Kind, target: String, readOnly: Bool = false) {
        self.kind = kind
        self.target = target
        self.readOnly = readOnly
    }
}

public struct ComposeDependency: Sendable, Hashable {
    public enum Condition: String, Sendable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completedSuccessfully = "service_completed_successfully"
    }

    public var service: String
    public var condition: Condition
    /// Whether the dependency must be part of the project for this service to start.
    public var required: Bool
    /// Compose restarts this service when the dependency is restarted. Recorded, not acted on.
    public var restart: Bool

    public init(service: String, condition: Condition = .started, required: Bool = true, restart: Bool = false) {
        self.service = service
        self.condition = condition
        self.required = required
        self.restart = restart
    }
}

/// A service's `healthcheck:`, as compose gives it to the engine, which runs it. What it
/// leaves out is the image's `HEALTHCHECK`, as Docker merges them: no test keeps the image's
/// command with this timing, and a field not given keeps the image's value, or the default.
public struct ComposeHealthcheck: Sendable, Equatable, Codable {
    /// The command, as an argument vector: `CMD-SHELL` and the string form are already
    /// `/bin/sh -c ...`. Empty: the image's.
    public var test: [String]
    /// Seconds.
    public var interval: Double?
    public var timeout: Double?
    public var retries: Int?
    public var startPeriod: Double?
    /// How often to check during the start period.
    public var startInterval: Double?
    /// `disable: true` or a test of `NONE`: the image's check is turned off too.
    public var disabled: Bool?

    public init(
        test: [String] = [], interval: Double? = nil, timeout: Double? = nil, retries: Int? = nil, startPeriod: Double? = nil,
        startInterval: Double? = nil, disabled: Bool? = nil
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
        self.disabled = disabled
    }

    /// The check turned off.
    public static var off: ComposeHealthcheck { ComposeHealthcheck(disabled: true) }

    public var isDisabled: Bool { disabled == true }

    /// The check in the engine's terms, to be laid over the image's when the container is
    /// made, as the `--health-*` flags are.
    public var engineCheck: HealthCheckConfiguration {
        guard !isDisabled else { return .disabled }
        func nanoseconds(_ seconds: Double?) -> Int64 {
            guard let seconds, seconds > 0 else { return 0 }
            return Int64((seconds * 1_000_000_000).rounded())
        }
        return HealthCheckConfiguration(
            test: test.isEmpty ? [] : [HealthCheckConfiguration.execTest] + test,
            interval: nanoseconds(interval),
            timeout: nanoseconds(timeout),
            startPeriod: nanoseconds(startPeriod),
            startInterval: nanoseconds(startInterval),
            retries: max(retries ?? 0, 0))
    }
}

public struct ComposeServiceNetwork: Sendable, Hashable {
    /// The network's key under the top-level `networks:`, or `default`.
    public var key: String
    public var aliases: [String]
    public var macAddress: String?

    public init(key: String, aliases: [String] = [], macAddress: String? = nil) {
        self.key = key
        self.aliases = aliases
        self.macAddress = macAddress
    }
}

public enum ComposePullPolicy: String, Sendable {
    case always
    case missing
    case never
    case build
}

public struct ComposeUlimit: Sendable, Hashable {
    public var name: String
    public var soft: String
    public var hard: String?

    public init(name: String, soft: String, hard: String? = nil) {
        self.name = name
        self.soft = soft
        self.hard = hard
    }
}

public struct ComposeNetwork: Sendable, Equatable {
    /// The key under `networks:`, which is what services refer to.
    public var key: String
    /// The `name:` the file gives the network, replacing `<project>_<key>`.
    public var name: String?
    /// The network is someone else's: it has to exist, and `down` leaves it.
    public var external = false
    /// No route out of the host.
    public var isInternal = false
    public var subnet: String?
    public var labels: [String: String] = [:]

    public init(key: String) {
        self.key = key
    }
}

public struct ComposeVolume: Sendable, Equatable {
    public var key: String
    public var name: String?
    public var external = false
    public var labels: [String: String] = [:]

    public init(key: String) {
        self.key = key
    }
}
