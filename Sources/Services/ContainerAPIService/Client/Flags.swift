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
import ContainerizationError
import Foundation

public struct Flags {
    public struct Logging: ParsableArguments {
        public init() {}

        public init(debug: Bool) {
            self.debug = debug
        }

        @Flag(name: .long, help: "Enable debug output [environment: CONTAINER_DEBUG]")
        public var debug = false
    }

    public struct Process: ParsableArguments {
        public init() {}

        public init(
            cwd: String?,
            env: [String],
            envFile: [String],
            gid: UInt32?,
            interactive: Bool,
            tty: Bool,
            uid: UInt32?,
            ulimits: [String],
            user: String?
        ) {
            self.cwd = cwd
            self.env = env
            self.envFile = envFile
            self.gid = gid
            self.interactive = interactive
            self.tty = tty
            self.uid = uid
            self.ulimits = ulimits
            self.user = user
        }

        @Option(name: .shortAndLong, help: "Set environment variables (key=value, or just key to inherit from host)")
        public var env: [String] = []

        @Option(
            name: .long,
            help: "Read in a file of environment variables (key=value format, ignores # comments and blank lines)"
        )
        public var envFile: [String] = []

        @Option(name: .long, help: "Set the group ID for the process")
        public var gid: UInt32?

        @Flag(name: .shortAndLong, help: "Keep the standard input open even if not attached")
        public var interactive = false

        @Flag(name: .shortAndLong, help: "Open a TTY with the process")
        public var tty = false

        @Option(name: .shortAndLong, help: "Set the user for the process (format: name|uid[:gid])")
        public var user: String?

        @Option(name: .long, help: "Set the user ID for the process")
        public var uid: UInt32?

        @Option(
            name: [.customShort("w"), .customLong("workdir"), .long],
            help: .init(
                "Set the initial working directory inside the container",
                valueName: "dir"
            )
        )
        public var cwd: String?

        @Option(
            name: .customLong("ulimit"),
            help: .init(
                "Set resource limits (format: <type>=<soft>[:<hard>])",
                valueName: "limit"
            )
        )
        public var ulimits: [String] = []
    }

    public struct Resource: ParsableArguments {
        public init() {}

        public init(cpus: Int64?, memory: String?) {
            self.cpus = cpus
            self.memory = memory
        }

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the container")
        public var cpus: Int64?

        @Option(
            name: .shortAndLong,
            help: "Amount of memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        public var memory: String?
    }

    public struct DNS: ParsableArguments {
        public init() {}

        public init(domain: String?, nameservers: [String], options: [String], searchDomains: [String]) {
            self.domain = domain
            self.nameservers = nameservers
            self.options = options
            self.searchDomains = searchDomains
        }

        @Option(
            name: .customLong("dns"),
            help: .init("DNS nameserver IP address", valueName: "ip")
        )
        public var nameservers: [String] = []

        @Option(
            name: .customLong("dns-domain"),
            help: .init("Default DNS domain", valueName: "domain")
        )
        public var domain: String? = nil

        @Option(
            name: .customLong("dns-option"),
            help: .init("DNS options", valueName: "option")
        )
        public var options: [String] = []

        @Option(
            name: .customLong("dns-search"),
            help: .init("DNS search domains", valueName: "domain")
        )
        public var searchDomains: [String] = []
    }

    public struct Registry: ParsableArguments {
        public init() {}

        public init(scheme: String) {
            self.scheme = scheme
        }

        @Option(help: "Scheme to use when connecting to the container registry. One of (http, https)")
        public var scheme: String = "https"
    }

    public struct Management: ParsableArguments {
        public init() {}

        public init(
            addHosts: [String],
            arch: String,
            capAdd: [String],
            capDrop: [String],
            cidfile: String,
            detach: Bool,
            dns: Flags.DNS,
            dnsDisabled: Bool,
            entrypoint: String?,
            hostname: String?,
            initImage: String?,
            kernel: String?,
            kernelArgs: [String],
            labels: [String],
            maskedPaths: [String],
            mounts: [String],
            name: String?,
            networks: [String],
            os: String,
            platform: String?,
            publishPorts: [String],
            publishSockets: [String],
            readOnly: Bool,
            readonlyPaths: [String],
            remove: Bool,
            restart: String?,
            rosetta: Bool,
            runtime: String?,
            ssh: Bool,
            shmSize: String?,
            sysctls: [String],
            tmpFs: [String],
            useInit: Bool,
            virtualization: Bool,
            volumes: [String],
            networkAliases: [String] = []
        ) {
            self.addHosts = addHosts
            self.arch = arch
            self.capAdd = capAdd
            self.capDrop = capDrop
            self.cidfile = cidfile
            self.detach = detach
            self.dns = dns
            self.dnsDisabled = dnsDisabled
            self.entrypoint = entrypoint
            self.hostname = hostname
            self.initImage = initImage
            self.kernel = kernel
            self.kernelArgs = kernelArgs
            self.labels = labels
            self.maskedPaths = maskedPaths
            self.mounts = mounts
            self.name = name
            self.networks = networks
            self.networkAliases = networkAliases
            self.os = os
            self.platform = platform
            self.publishPorts = publishPorts
            self.publishSockets = publishSockets
            self.readOnly = readOnly
            self.readonlyPaths = readonlyPaths
            self.remove = remove
            self.restart = restart
            self.rosetta = rosetta
            self.runtime = runtime
            self.ssh = ssh
            self.shmSize = shmSize
            self.sysctls = sysctls
            self.tmpFs = tmpFs
            self.useInit = useInit
            self.virtualization = virtualization
            self.volumes = volumes
        }

        @Option(
            name: .customLong("add-host"),
            help: .init(
                "Add a name the container resolves to a fixed address (format: <name>:<ip>, or <name>:host-gateway for this Mac)",
                valueName: "host"
            )
        )
        public var addHosts: [String] = []

        @Option(name: .shortAndLong, help: "Set arch if image can target multiple architectures")
        public var arch: String = Arch.hostArchitecture().rawValue

        @Option(
            name: .customLong("cap-add"),
            help: .init("Add a Linux capability (e.g. CAP_NET_RAW, or ALL)", valueName: "cap")
        )
        public var capAdd: [String] = []

        @Option(
            name: .customLong("cap-drop"),
            help: .init("Drop a Linux capability (e.g. CAP_NET_RAW, or ALL)", valueName: "cap")
        )
        public var capDrop: [String] = []

        @Option(name: .long, help: "Write the container ID to the path provided")
        public var cidfile = ""

        @Flag(name: .shortAndLong, help: "Run the container and detach from the process")
        public var detach = false

        @OptionGroup
        public var dns: Flags.DNS

        @Option(
            name: .long,
            help: .init(
                "Override the entrypoint of the image",
                valueName: "cmd"
            )
        )
        public var entrypoint: String?

        @Option(name: .long, help: "Set the hostname the container sees (default: the container's name)")
        public var hostname: String?

        @Flag(name: .customLong("init"), help: "Run an init process inside the container that forwards signals and reaps processes")
        public var useInit = false

        @Option(
            name: .long,
            help: .init("Use a custom init image instead of the default", valueName: "image")
        )
        public var initImage: String?

        @Option(
            name: .shortAndLong,
            help: .init("Set a custom kernel path", valueName: "path"),
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            }
        )
        public var kernel: String?

        @Option(
            name: .customLong("kernel-arg"),
            help: .init(
                "Append a raw boot argument to the kernel command line (repeatable).",
                valueName: "arg"
            )
        )
        public var kernelArgs: [String] = []

        @Option(name: [.short, .customLong("label")], help: "Add a key=value label to the container")
        public var labels: [String] = []

        /// EXPERIMENTAL: The flag is subject to change.
        @Option(
            name: .customLong("masked-path"),
            help: .init(
                "[EXPERIMENTAL] Hide a path inside the container, in addition to the runtime defaults (or NONE to clear prior values and the defaults)",
                valueName: "path"
            )
        )
        public var maskedPaths: [String] = []

        @Option(name: .customLong("mount"), help: "Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)")
        public var mounts: [String] = []

        @Option(name: .long, help: "Use the specified name as the container ID")
        public var name: String?

        @Option(name: [.customLong("network")], help: "Attach the container to a network (format: <name>[,mac=XX:XX:XX:XX:XX:XX][,mtu=VALUE][,alias=NAME])")
        public var networks: [String] = []

        @Option(name: .customLong("network-alias"), help: "Add a name the container answers to on every network it attaches to")
        public var networkAliases: [String] = []

        @Flag(name: [.customLong("no-dns")], help: "Do not configure DNS in the container")
        public var dnsDisabled = false

        @Option(name: .long, help: "Set OS if image can target multiple operating systems")
        public var os = "linux"

        @Option(
            name: [.customShort("p"), .customLong("publish")],
            help: .init(
                "Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])",
                valueName: "spec"
            )
        )
        public var publishPorts: [String] = []

        @Option(name: .long, help: "Platform for the image if it's multi-platform. This takes precedence over --os and --arch [environment: CONTAINER_DEFAULT_PLATFORM]")
        public var platform: String?

        @Option(
            name: .customLong("publish-socket"),
            help: .init(
                "Publish a socket from container to host (format: host_path:container_path)",
                valueName: "spec"
            )
        )
        public var publishSockets: [String] = []

        @Flag(name: .long, help: "Mount the container's root filesystem as read-only")
        public var readOnly = false

        /// EXPERIMENTAL: The flag is subject to change.
        @Option(
            name: .customLong("read-only-path"),
            help: .init(
                "[EXPERIMENTAL] Mark a path inside the container read-only, in addition to the runtime defaults (or NONE to clear prior values and the defaults)",
                valueName: "path"
            )
        )
        public var readonlyPaths: [String] = []

        @Flag(name: [.customLong("rm"), .long], help: "Remove the container after it stops")
        public var remove = false

        @Option(
            name: .long,
            help: .init(
                "Policy stored on the container: no, always, unless-stopped or on-failure[:<n>]. SiliconShip applies always/unless-stopped at app-managed engine start: always includes manually stopped containers; unless-stopped restores the last app shutdown's running set. Standalone engine starts and process exits do not apply this policy yet",
                valueName: "policy"
            )
        )
        public var restart: String?

        @Flag(name: .long, help: "Enable Rosetta in the container")
        public var rosetta = false

        @Option(name: .long, help: "Set the runtime handler for the container (default: container-runtime-linux)")
        public var runtime: String?

        @Flag(name: .long, help: "Forward SSH agent socket to container")
        public var ssh = false

        @Option(name: .customLong("shm-size"), help: "Size of /dev/shm (e.g. 64M, 1G)")
        public var shmSize: String?

        @Option(
            name: .customLong("sysctl"),
            help: .init(
                "Set a kernel parameter in the container (format: <key>=<value>)",
                valueName: "sysctl"
            )
        )
        public var sysctls: [String] = []

        @Option(name: .customLong("tmpfs"), help: "Add a tmpfs mount to the container at the given path")
        public var tmpFs: [String] = []

        @Flag(
            name: .long,
            help:
                "Expose virtualization capabilities to the container (requires host and guest support)"
        )
        public var virtualization: Bool = false

        @Option(name: [.customLong("volume"), .short], help: "Bind mount a volume into the container")
        public var volumes: [String] = []

        public func validate() throws {
            if dnsDisabled {
                let hasDNSConfig =
                    !dns.nameservers.isEmpty
                    || dns.domain != nil
                    || !dns.options.isEmpty
                    || !dns.searchDomains.isEmpty
                if hasDNSConfig {
                    throw ValidationError(
                        "`--no-dns` cannot be used with DNS configuration flags (`--dns`, `--dns-domain`, `--dns-option`, `--dns-search`)"
                    )
                }
            }
        }
    }

    /// Flags of other container tools that this engine cannot honour. Accepted so that a
    /// command copied from a README, a script or another tool runs as it is: each one
    /// given is reported on stderr and ignored, and the container runs without it. Hidden
    /// from help, where the flags to learn are the ones that do something.
    public struct Unsupported: ParsableArguments {
        public init() {}
        @Flag(name: .customLong("privileged"), help: .hidden)
        public var privileged = false
        @Flag(name: .customLong("oom-kill-disable"), help: .hidden)
        public var oomKillDisable = false
        @Flag(name: .customLong("no-healthcheck"), help: .hidden)
        public var noHealthcheck = false
        @Flag(name: [.customShort("P"), .customLong("publish-all")], help: .hidden)
        public var publishAll = false
        @Option(name: .customLong("pid"), help: .hidden)
        public var pid: String?
        @Option(name: .customLong("ipc"), help: .hidden)
        public var ipc: String?
        @Option(name: .customLong("uts"), help: .hidden)
        public var uts: String?
        @Option(name: .customLong("userns"), help: .hidden)
        public var userns: String?
        @Option(name: .customLong("cgroupns"), help: .hidden)
        public var cgroupns: String?
        @Option(name: .customLong("cgroup-parent"), help: .hidden)
        public var cgroupParent: String?
        @Option(name: .customLong("oom-score-adj"), help: .hidden)
        public var oomScoreAdj: String?
        @Option(name: .customLong("log-driver"), help: .hidden)
        public var logDriver: String?
        @Option(name: .customLong("gpus"), help: .hidden)
        public var gpus: String?
        @Option(name: .customLong("isolation"), help: .hidden)
        public var isolation: String?
        @Option(name: .customLong("stop-signal"), help: .hidden)
        public var stopSignal: String?
        @Option(name: .customLong("stop-timeout"), help: .hidden)
        public var stopTimeout: String?
        @Option(name: .customLong("health-cmd"), help: .hidden)
        public var healthCmd: String?
        @Option(name: .customLong("health-interval"), help: .hidden)
        public var healthInterval: String?
        @Option(name: .customLong("health-retries"), help: .hidden)
        public var healthRetries: String?
        @Option(name: .customLong("health-start-period"), help: .hidden)
        public var healthStartPeriod: String?
        @Option(name: .customLong("health-start-interval"), help: .hidden)
        public var healthStartInterval: String?
        @Option(name: .customLong("health-timeout"), help: .hidden)
        public var healthTimeout: String?
        @Option(name: .customLong("ip"), help: .hidden)
        public var ip: String?
        @Option(name: .customLong("ip6"), help: .hidden)
        public var ip6: String?
        @Option(name: .customLong("mac-address"), help: .hidden)
        public var macAddress: String?
        @Option(name: .customLong("domainname"), help: .hidden)
        public var domainname: String?
        @Option(name: .customLong("memory-swap"), help: .hidden)
        public var memorySwap: String?
        @Option(name: .customLong("memory-swappiness"), help: .hidden)
        public var memorySwappiness: String?
        @Option(name: .customLong("memory-reservation"), help: .hidden)
        public var memoryReservation: String?
        @Option(name: .customLong("kernel-memory"), help: .hidden)
        public var kernelMemory: String?
        @Option(name: .customLong("cpu-shares"), help: .hidden)
        public var cpuShares: String?
        @Option(name: .customLong("cpu-period"), help: .hidden)
        public var cpuPeriod: String?
        @Option(name: .customLong("cpu-quota"), help: .hidden)
        public var cpuQuota: String?
        @Option(name: .customLong("cpuset-cpus"), help: .hidden)
        public var cpusetCpus: String?
        @Option(name: .customLong("cpuset-mems"), help: .hidden)
        public var cpusetMems: String?
        @Option(name: .customLong("blkio-weight"), help: .hidden)
        public var blkioWeight: String?
        @Option(name: .customLong("pids-limit"), help: .hidden)
        public var pidsLimit: String?
        @Option(name: .customLong("detach-keys"), help: .hidden)
        public var detachKeys: String?
        @Option(name: .customLong("volume-driver"), help: .hidden)
        public var volumeDriver: String?
        @Option(name: .customLong("device"), help: .hidden)
        public var device: [String] = []
        @Option(name: .customLong("device-cgroup-rule"), help: .hidden)
        public var deviceCgroupRule: [String] = []
        @Option(name: .customLong("security-opt"), help: .hidden)
        public var securityOpt: [String] = []
        @Option(name: .customLong("log-opt"), help: .hidden)
        public var logOpt: [String] = []
        @Option(name: .customLong("storage-opt"), help: .hidden)
        public var storageOpt: [String] = []
        @Option(name: .customLong("link"), help: .hidden)
        public var link: [String] = []
        @Option(name: .customLong("expose"), help: .hidden)
        public var expose: [String] = []
        @Option(name: .customLong("group-add"), help: .hidden)
        public var groupAdd: [String] = []
        @Option(name: .customLong("blkio-weight-device"), help: .hidden)
        public var blkioWeightDevice: [String] = []
        @Option(name: .customLong("device-read-bps"), help: .hidden)
        public var deviceReadBps: [String] = []
        @Option(name: .customLong("device-read-iops"), help: .hidden)
        public var deviceReadIops: [String] = []
        @Option(name: .customLong("device-write-bps"), help: .hidden)
        public var deviceWriteBps: [String] = []
        @Option(name: .customLong("device-write-iops"), help: .hidden)
        public var deviceWriteIops: [String] = []
        @Option(name: .customLong("attach"), help: .hidden)
        public var attach: [String] = []
        @Option(name: .customLong("annotation"), help: .hidden)
        public var annotation: [String] = []
        @Option(name: .customLong("label-file"), help: .hidden)
        public var labelFile: [String] = []
        @Option(name: .customLong("volumes-from"), help: .hidden)
        public var volumesFrom: [String] = []

        /// The flags that were given, spelled the way they were typed, in declaration order.
        public var given: [String] {
            var names: [String] = []
            if privileged { names.append("--privileged") }
            if oomKillDisable { names.append("--oom-kill-disable") }
            if noHealthcheck { names.append("--no-healthcheck") }
            if publishAll { names.append("--publish-all") }
            if pid != nil { names.append("--pid") }
            if ipc != nil { names.append("--ipc") }
            if uts != nil { names.append("--uts") }
            if userns != nil { names.append("--userns") }
            if cgroupns != nil { names.append("--cgroupns") }
            if cgroupParent != nil { names.append("--cgroup-parent") }
            if oomScoreAdj != nil { names.append("--oom-score-adj") }
            if logDriver != nil { names.append("--log-driver") }
            if gpus != nil { names.append("--gpus") }
            if isolation != nil { names.append("--isolation") }
            if stopSignal != nil { names.append("--stop-signal") }
            if stopTimeout != nil { names.append("--stop-timeout") }
            if healthCmd != nil { names.append("--health-cmd") }
            if healthInterval != nil { names.append("--health-interval") }
            if healthRetries != nil { names.append("--health-retries") }
            if healthStartPeriod != nil { names.append("--health-start-period") }
            if healthStartInterval != nil { names.append("--health-start-interval") }
            if healthTimeout != nil { names.append("--health-timeout") }
            if ip != nil { names.append("--ip") }
            if ip6 != nil { names.append("--ip6") }
            if macAddress != nil { names.append("--mac-address") }
            if domainname != nil { names.append("--domainname") }
            if memorySwap != nil { names.append("--memory-swap") }
            if memorySwappiness != nil { names.append("--memory-swappiness") }
            if memoryReservation != nil { names.append("--memory-reservation") }
            if kernelMemory != nil { names.append("--kernel-memory") }
            if cpuShares != nil { names.append("--cpu-shares") }
            if cpuPeriod != nil { names.append("--cpu-period") }
            if cpuQuota != nil { names.append("--cpu-quota") }
            if cpusetCpus != nil { names.append("--cpuset-cpus") }
            if cpusetMems != nil { names.append("--cpuset-mems") }
            if blkioWeight != nil { names.append("--blkio-weight") }
            if pidsLimit != nil { names.append("--pids-limit") }
            if detachKeys != nil { names.append("--detach-keys") }
            if volumeDriver != nil { names.append("--volume-driver") }
            if !device.isEmpty { names.append("--device") }
            if !deviceCgroupRule.isEmpty { names.append("--device-cgroup-rule") }
            if !securityOpt.isEmpty { names.append("--security-opt") }
            if !logOpt.isEmpty { names.append("--log-opt") }
            if !storageOpt.isEmpty { names.append("--storage-opt") }
            if !link.isEmpty { names.append("--link") }
            if !expose.isEmpty { names.append("--expose") }
            if !groupAdd.isEmpty { names.append("--group-add") }
            if !blkioWeightDevice.isEmpty { names.append("--blkio-weight-device") }
            if !deviceReadBps.isEmpty { names.append("--device-read-bps") }
            if !deviceReadIops.isEmpty { names.append("--device-read-iops") }
            if !deviceWriteBps.isEmpty { names.append("--device-write-bps") }
            if !deviceWriteIops.isEmpty { names.append("--device-write-iops") }
            if !attach.isEmpty { names.append("--attach") }
            if !annotation.isEmpty { names.append("--annotation") }
            if !labelFile.isEmpty { names.append("--label-file") }
            if !volumesFrom.isEmpty { names.append("--volumes-from") }
            return names
        }
    }

    public struct Progress: ParsableArguments {
        public init() {}

        public init(progress: ProgressType) {
            self.progress = progress
        }

        public enum ProgressType: String, ExpressibleByArgument {
            case auto
            case none
            case ansi
            case plain
            case color
        }

        @Option(name: .long, help: ArgumentHelp("Progress type (format: auto|none|ansi|plain|color)", valueName: "type"))
        public var progress: ProgressType = .auto
    }

    public struct ImageFetch: ParsableArguments {
        /// When the image is fetched from its registry, and when what is local is enough.
        public enum PullPolicy: String, ExpressibleByArgument, CaseIterable, Sendable {
            /// Fetch from the registry every time, so a moving tag is followed.
            case always
            /// Fetch only when there is no local image for the reference and platform.
            case missing
            /// Never fetch; fail when the image is not local.
            case never
        }

        public init() {}

        public init(maxConcurrentDownloads: Int, pull: PullPolicy = .missing) {
            self.maxConcurrentDownloads = maxConcurrentDownloads
            self.pull = pull
        }

        @Option(name: .long, help: "Maximum number of concurrent downloads")
        public var maxConcurrentDownloads: Int = 3

        @Option(name: .long, help: "When to fetch the image from its registry: always, missing or never")
        public var pull: PullPolicy = .missing
    }
}
