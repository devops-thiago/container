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
import Testing

@testable import DockerAPIService

struct ContainerCreateMapperTests {
    /// `docker run -it alpine` as the CLI encodes it: most fields present and zero-valued.
    static let runInteractive = """
        {"Hostname":"","Domainname":"","User":"","AttachStdin":true,"AttachStdout":true,"AttachStderr":true,"Tty":true,"OpenStdin":true,
        "StdinOnce":true,"Env":[],"Cmd":null,"Image":"alpine","Volumes":{},"WorkingDir":"","Entrypoint":null,"OnBuild":null,"Labels":{},
        "HostConfig":{"Binds":null,"ContainerIDFile":"","LogConfig":{"Type":"","Config":{}},"NetworkMode":"default","PortBindings":{},
        "RestartPolicy":{"Name":"no","MaximumRetryCount":0},"AutoRemove":false,"VolumeDriver":"","VolumesFrom":null,"ConsoleSize":[50,120],
        "CapAdd":null,"CapDrop":null,"CgroupnsMode":"","Dns":[],"DnsOptions":[],"DnsSearch":[],"ExtraHosts":null,"GroupAdd":null,"IpcMode":"",
        "Cgroup":"","Links":null,"OomScoreAdj":0,"PidMode":"","Privileged":false,"PublishAllPorts":false,"ReadonlyRootfs":false,"SecurityOpt":null,
        "UTSMode":"","UsernsMode":"","ShmSize":0,"Isolation":"","CpuShares":0,"Memory":0,"NanoCpus":0,"CgroupParent":"","BlkioWeight":0,
        "CpusetCpus":"","CpusetMems":"","Devices":[],"DeviceCgroupRules":null,"DeviceRequests":null,"MemoryReservation":0,"MemorySwap":0,
        "MemorySwappiness":null,"OomKillDisable":null,"PidsLimit":null,"Ulimits":[],"CpuCount":0,"CpuPercent":0,"MaskedPaths":null,"ReadonlyPaths":null},
        "NetworkingConfig":{"EndpointsConfig":{}}}
        """

    /// `docker run -d -p 8080:80 nginx`.
    static let runPublished = """
        {"Hostname":"","User":"","AttachStdin":false,"AttachStdout":false,"AttachStderr":false,"ExposedPorts":{"80/tcp":{}},"Tty":false,
        "OpenStdin":false,"StdinOnce":false,"Env":[],"Cmd":null,"Image":"nginx","Volumes":{},"WorkingDir":"","Entrypoint":null,"Labels":{},
        "HostConfig":{"Binds":null,"LogConfig":{"Type":"","Config":{}},"NetworkMode":"default","PortBindings":{"80/tcp":[{"HostIp":"","HostPort":"8080"}]},
        "RestartPolicy":{"Name":"no","MaximumRetryCount":0},"AutoRemove":false,"Privileged":false,"Devices":[],"Memory":0,"NanoCpus":0,
        "Dns":[],"DnsOptions":[],"DnsSearch":[],"PidMode":"","IpcMode":"","UTSMode":"","UsernsMode":"","Ulimits":[],"ShmSize":0},
        "NetworkingConfig":{"EndpointsConfig":{}}}
        """

    private func errorMessage(_ body: () throws -> Void) -> DockerAPIError? {
        do {
            try body()
            return nil
        } catch let error as DockerAPIError {
            return error
        } catch {
            return DockerAPIError.internalError("\(error)")
        }
    }

    @Test("docker run -it alpine maps to the image's command on a terminal, with no warnings")
    func runInteractive() throws {
        let plan = try Fixtures.plan(Self.runInteractive)
        #expect(plan.warnings.isEmpty)
        let process = plan.configuration.initProcess
        #expect(process.executable == "/bin/sh")
        #expect(process.arguments.isEmpty)
        #expect(process.terminal)
        #expect(process.workingDirectory == "/")
        #expect(process.user == .id(uid: 0, gid: 0))
        #expect(process.environment == ["PATH=/usr/bin:/bin"])
        #expect(plan.configuration.id == "abcdef012345")
        #expect(plan.configuration.networks.map(\.network) == [Fixtures.builtin])
        #expect(plan.configuration.networks.first?.options.hostname == "abcdef012345")
        #expect(plan.configuration.networks.first?.options.aliases == [])
        #expect(plan.configuration.resources.cpus == 4)
        #expect(plan.configuration.resources.memoryInBytes == 1 << 30)
        #expect(plan.configuration.restartPolicy == nil)
        #expect(plan.configuration.labels[DockerLabels.id] == Fixtures.reservation.dockerID)
        #expect(plan.configuration.labels[DockerLabels.name] == "web")
        #expect(plan.configuration.labels[DockerLabels.image] == "alpine")
        #expect(plan.configuration.labels[DockerLabels.imageID] == Fixtures.configDigest)
        #expect(plan.extras.openStdin && plan.extras.stdinOnce && plan.extras.attachStdin)
        #expect(plan.extras.networkMode == "bridge")
        #expect(!plan.autoRemove)
        #expect(plan.volumes.isEmpty)
        #expect(plan.configuration.mounts.isEmpty)
        // Control: the same command without a terminal.
        let detached = try Fixtures.plan(#"{"Image":"alpine","Tty":false}"#)
        #expect(!detached.configuration.initProcess.terminal)
        #expect(!detached.extras.openStdin)
    }

    @Test("docker run -d -p 8080:80 nginx publishes the port, with no warnings")
    func runPublished() throws {
        let plan = try Fixtures.plan(Self.runPublished, reference: "nginx")
        #expect(plan.warnings.isEmpty)
        let port = try #require(plan.configuration.publishedPorts.first)
        #expect(plan.configuration.publishedPorts.count == 1)
        #expect(port.hostPort == 8080)
        #expect(port.containerPort == 80)
        #expect(port.proto == .tcp)
        #expect(port.hostAddress.description == "0.0.0.0")
        #expect(plan.extras.exposedPorts == ["80/tcp"])
        // Control: a create that publishes nothing has no ports.
        #expect(try Fixtures.plan(Self.runInteractive).configuration.publishedPorts.isEmpty)
    }

    @Test("Cmd replaces the image's command and keeps its entrypoint")
    func cmdReplacesCommand() throws {
        let image = Fixtures.image(entrypoint: ["docker-entrypoint.sh"], cmd: ["postgres"])
        let given = try Fixtures.plan(#"{"Image":"postgres","Cmd":["bash"]}"#, image: image).configuration.initProcess
        #expect([given.executable] + given.arguments == ["docker-entrypoint.sh", "bash"])
        // Control: without a Cmd the image's runs.
        let inherited = try Fixtures.plan(#"{"Image":"postgres"}"#, image: image).configuration.initProcess
        #expect([inherited.executable] + inherited.arguments == ["docker-entrypoint.sh", "postgres"])
    }

    @Test("Entrypoint replaces the image's entrypoint and command both")
    func entrypointReplacesBoth() throws {
        let image = Fixtures.image(entrypoint: ["docker-entrypoint.sh"], cmd: ["postgres"])
        let replaced = try Fixtures.plan(#"{"Image":"postgres","Entrypoint":["/bin/echo"]}"#, image: image)
        #expect([replaced.configuration.initProcess.executable] + replaced.configuration.initProcess.arguments == ["/bin/echo"])
        #expect(replaced.extras.entrypoint == ["/bin/echo"])
        #expect(replaced.extras.cmd == nil)
        // An empty list clears the entrypoint but leaves the image's command.
        let cleared = try Fixtures.plan(#"{"Image":"postgres","Entrypoint":[]}"#, image: image).configuration.initProcess
        #expect([cleared.executable] + cleared.arguments == ["postgres"])
        // `--entrypoint ""` clears both, so a command has to be given.
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"postgres","Entrypoint":[""]}"#, image: image) } == .badRequest("no command specified"))
        let given = try Fixtures.plan(#"{"Image":"postgres","Entrypoint":[""],"Cmd":["ls"]}"#, image: image).configuration.initProcess
        #expect([given.executable] + given.arguments == ["ls"])
    }

    @Test("a single string is read as a one-word Cmd or Entrypoint")
    func stringCommand() throws {
        let plan = try Fixtures.plan(#"{"Image":"alpine","Entrypoint":"/bin/date","Cmd":"-u"}"#)
        #expect(plan.configuration.initProcess.executable == "/bin/date")
        #expect(plan.configuration.initProcess.arguments == ["-u"])
        // Control: lists are taken as given.
        let listed = try Fixtures.plan(#"{"Image":"alpine","Entrypoint":["/bin/date"],"Cmd":["-u","+%s"]}"#)
        #expect(listed.configuration.initProcess.arguments == ["-u", "+%s"])
    }

    @Test("no command from the client or the image is refused")
    func noCommand() throws {
        let bare = Fixtures.image(entrypoint: nil, cmd: nil)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"scratch"}"#, image: bare) } == .badRequest("no command specified"))
        // Control: the client's own command is enough.
        #expect(try Fixtures.plan(#"{"Image":"scratch","Cmd":["/app"]}"#, image: bare).configuration.initProcess.executable == "/app")
    }

    @Test("Env adds to the image's by key, and an entry without a key is refused")
    func environment() throws {
        let image = Fixtures.image(env: ["PATH=/usr/bin", "LANG=C"])
        let plan = try Fixtures.plan(#"{"Image":"alpine","Env":["FOO=1","PATH=/x"]}"#, image: image)
        #expect(plan.configuration.initProcess.environment == ["FOO=1", "PATH=/x", "LANG=C"])
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","Env":["=x"]}"#) } == .badRequest("invalid environment variable: =x"))
        // Control: no Env is the image's.
        #expect(try Fixtures.plan(#"{"Image":"alpine"}"#, image: image).configuration.initProcess.environment == ["PATH=/usr/bin", "LANG=C"])
    }

    @Test("User, WorkingDir and StopSignal fall back to the image's")
    func scalarDefaults() throws {
        let image = Fixtures.image(user: "nginx", workingDir: "/srv", stopSignal: "SIGQUIT")
        let inherited = try Fixtures.plan(#"{"Image":"nginx","User":"","WorkingDir":""}"#, image: image)
        #expect(inherited.configuration.initProcess.user == .raw(userString: "nginx"))
        #expect(inherited.configuration.initProcess.workingDirectory == "/srv")
        #expect(inherited.configuration.stopSignal == "SIGQUIT")
        let given = try Fixtures.plan(#"{"Image":"nginx","User":"1000:1000","WorkingDir":"/app","StopSignal":"SIGTERM"}"#, image: image)
        #expect(given.configuration.initProcess.user == .raw(userString: "1000:1000"))
        #expect(given.configuration.initProcess.workingDirectory == "/app")
        #expect(given.configuration.stopSignal == "SIGTERM")
    }

    @Test("the image's labels are added, its reserved ones dropped, and a client's reserved one refused")
    func labels() throws {
        let image = Fixtures.image(labels: ["maintainer": "x", "keep": "image", DockerLabels.name: "evil", ResourceLabelKeys.plugin: "builder"])
        let plan = try Fixtures.plan(#"{"Image":"alpine","Labels":{"keep":"mine","app":"web"}}"#, image: image)
        #expect(plan.configuration.labels["maintainer"] == "x")
        #expect(plan.configuration.labels["keep"] == "mine")
        #expect(plan.configuration.labels["app"] == "web")
        #expect(plan.configuration.labels[DockerLabels.name] == "web")
        #expect(plan.configuration.labels[ResourceLabelKeys.plugin] == nil)
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","Labels":{"com.apple.container.plugin":"x"}}"#) }
                == .badRequest("the label com.apple.container.plugin is reserved"))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","Labels":{"dev.siliconship.docker.id":"x"}}"#) }?.status == .badRequest)
    }

    @Test("the health check is the client's over the image's, and NONE turns it off")
    func healthCheck() throws {
        let imageCheck = HealthCheckConfiguration(test: ["CMD", "true"], interval: 5_000_000_000)
        let image = Fixtures.image(healthCheck: imageCheck)
        #expect(try Fixtures.plan(#"{"Image":"alpine"}"#, image: image).configuration.healthCheck == imageCheck)
        let merged = try Fixtures.plan(#"{"Image":"alpine","Healthcheck":{"Interval":2000000000}}"#, image: image).configuration.healthCheck
        #expect(merged?.test == ["CMD", "true"])
        #expect(merged?.interval == 2_000_000_000)
        #expect(try Fixtures.plan(#"{"Image":"alpine","Healthcheck":{"Test":["NONE"]}}"#, image: image).configuration.healthCheck == nil)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","Healthcheck":{"Test":["CMD","true"],"Interval":5}}"#) }?.status == .badRequest)
        // Control: no check anywhere is none.
        #expect(try Fixtures.plan(#"{"Image":"alpine"}"#).configuration.healthCheck == nil)
    }

    @Test("host, none and container network modes are refused; bridge and default are the engine's default network")
    func networkModes() throws {
        for mode in ["host", "none", "container:abc"] {
            #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"NetworkMode":"\#(mode)"}}"#) }?.status == .badRequest)
        }
        for mode in ["", "default", "bridge"] {
            let plan = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"NetworkMode":"\#(mode)"}}"#)
            #expect(plan.configuration.networks.map(\.network) == [Fixtures.builtin])
            #expect(plan.extras.networkMode == "bridge")
        }
    }

    @Test("a named network is attached with the client's aliases and the container's name")
    func namedNetwork() throws {
        let plan = try Fixtures.plan(
            #"{"Image":"alpine","HostConfig":{"NetworkMode":"shop_default"},"NetworkingConfig":{"EndpointsConfig":{"shop_default":{"Aliases":["db"]},"bridge":null}}}"#
        )
        #expect(plan.configuration.networks.map(\.network) == ["shop_default", Fixtures.builtin])
        #expect(plan.configuration.networks[0].options.aliases == ["db", "web"])
        #expect(plan.configuration.networks[0].options.hostname == "abcdef012345")
        // Control: on the default network the name is no alias, as on Docker's bridge.
        #expect(plan.configuration.networks[1].options.aliases == [])
        #expect(plan.extras.networkMode == "shop_default")
    }

    @Test("an address an endpoint asks for is ignored with a warning; an IPAMConfig naming none says nothing")
    func endpointAddress() throws {
        func plan(_ ipam: String) throws -> DockerCreatePlan {
            try Fixtures.plan(
                #"{"Image":"alpine","HostConfig":{"NetworkMode":"shop_default"},"NetworkingConfig":{"EndpointsConfig":{"shop_default":{"IPAMConfig":\#(ipam)}}}}"#
            )
        }
        // Control: `docker run --network n` with no `--ip` sends no IPAMConfig; another client
        // may send it empty or with its fields empty. None of these is a request, or a warning.
        let plain = try plan("{}")
        for ipam in [#"{}"#, #"{"IPv4Address":"","IPv6Address":"","LinkLocalIPs":[]}"#, "null"] {
            let unaddressed = try plan(ipam)
            #expect(unaddressed.configuration.networks.map(\.network) == ["shop_default"])
            #expect(unaddressed.warnings.isEmpty)
        }
        // `docker run --ip`, `--ip6`, `--link-local-ip`, and compose's `ipv4_address` and
        // `ipv6_address`: the container is made on the network's own address, and told so.
        let cases = [
            (#"{"IPv4Address":"10.7.0.9"}"#, ["IPv4Address"]),
            (#"{"IPv6Address":"fd00::9"}"#, ["IPv6Address"]),
            (#"{"LinkLocalIPs":["169.254.0.9"]}"#, ["LinkLocalIPs"]),
            (#"{"IPv4Address":"10.7.0.9","IPv6Address":"fd00::9"}"#, ["IPv4Address", "IPv6Address"]),
        ]
        for (ipam, fields) in cases {
            let addressed = try plan(ipam)
            #expect(addressed.warnings == fields.map { "a static address is not supported by SiliconShip: the network assigns one; \($0) was ignored" })
            #expect(addressed.configuration.networks.map(\.network) == plain.configuration.networks.map(\.network))
            #expect(addressed.configuration.networks.map(\.options.hostname) == plain.configuration.networks.map(\.options.hostname))
            #expect(addressed.configuration.networks.map(\.options.aliases) == plain.configuration.networks.map(\.options.aliases))
            #expect(addressed.configuration.networks.allSatisfy { $0.options.macAddress == nil })
        }
    }

    @Test("Privileged and Devices are warned about only when given")
    func warnings() throws {
        let given = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Privileged":true,"Devices":[{"PathOnHost":"/dev/kvm"}],"CpuShares":512}}"#)
        #expect(given.warnings.count == 3)
        #expect(given.warnings.contains { $0.hasPrefix("Privileged mode is not supported") })
        #expect(given.warnings.contains { $0.hasPrefix("Devices are not supported") })
        // Control: the same fields zero-valued say nothing.
        #expect(try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Privileged":false,"Devices":[],"CpuShares":0}}"#).warnings.isEmpty)
        let modes = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"PidMode":"host","LogConfig":{"Type":"syslog"}}}"#)
        #expect(modes.warnings.count == 2)
    }

    /// Testcontainers' Ryuk container as docker-java 3.7.1 encodes it: nulls for what was not set,
    /// an empty binding for the exposed port, privileged, removed when it exits, and the Docker
    /// socket bind-mounted in.
    static func ryukCreate(socket: String) -> String {
        """
        {"Hostname":null,"Domainname":null,"User":null,"AttachStdin":null,"AttachStdout":null,"AttachStderr":null,"PortSpecs":null,
        "Tty":null,"OpenStdin":null,"StdinOnce":null,"Env":null,"Cmd":null,"Healthcheck":null,"ArgsEscaped":null,"Entrypoint":null,
        "Image":"testcontainers/ryuk:0.14.0","Volumes":{},"WorkingDir":null,"MacAddress":null,"OnBuild":null,"NetworkDisabled":null,
        "ExposedPorts":{"8080/tcp":{}},"StopSignal":null,"StopTimeout":null,
        "HostConfig":{"Binds":["\(socket):/var/run/docker.sock:rw"],"BlkioWeight":null,"CapAdd":null,"CapDrop":null,"Dns":null,
        "DnsOptions":null,"DnsSearch":null,"ExtraHosts":null,"GroupAdd":null,"Links":null,"LogConfig":null,"Memory":null,"NanoCpus":null,
        "NetworkMode":null,"PortBindings":{"8080/tcp":[{"HostIp":"","HostPort":""}]},"Privileged":true,"PublishAllPorts":null,
        "ReadonlyRootfs":null,"RestartPolicy":null,"Ulimits":null,"AutoRemove":true,"Mounts":null,"Init":null,"ShmSize":null,"Tmpfs":null,
        "Sysctls":null,"SecurityOpt":null,"VolumesFrom":null,"Devices":null,"DeviceRequests":null},
        "Labels":{"org.testcontainers":"true","org.testcontainers.lang":"java","org.testcontainers.version":"2.0.5"},
        "Shell":null,"NetworkingConfig":null}
        """
    }

    @Test("Ryuk's create, nulls and all, maps: its socket bind is a shared mount of the socket itself, its port takes a free one")
    func ryukCreate() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dapi-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appending(path: "d.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0)

        let plan = try Fixtures.plan(Self.ryukCreate(socket: socketPath), reference: "testcontainers/ryuk:0.14.0")
        let mount = try #require(plan.configuration.mounts.first)
        #expect(plan.configuration.mounts.count == 1)
        #expect(mount.isVirtiofs && mount.source == socketPath && mount.destination == "/var/run/docker.sock" && mount.options == [])
        // What the engine checks a grant for and the runtime relays: the socket, not its folder.
        #expect(mount.sharedFolder == socketPath)
        #expect(plan.autoRemove)
        #expect(plan.configuration.publishedPorts.map { "\($0.hostAddress):\($0.hostPort)->\($0.containerPort)" } == ["0.0.0.0:40001->8080"])
        #expect(plan.warnings == ["Privileged mode is not supported; the container runs unprivileged."])
        #expect(plan.configuration.labels["org.testcontainers"] == "true")
        // Control: a regular file bound the same way shares its folder, which is what a grant would be asked for.
        let file = directory.appending(path: "plain")
        try Data("x".utf8).write(to: file)
        let filePlan = try Fixtures.plan(Self.ryukCreate(socket: file.path), reference: "testcontainers/ryuk:0.14.0")
        #expect(filePlan.configuration.mounts.first?.sharedFolder == directory.resolvingSymlinksInPath().path)
    }

    @Test("binds map a host path to a shared folder and a name to a volume")
    func binds() throws {
        let plan = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["/Users/me/src:/src:ro","data:/data","/tmp/x:/x:rw,z"]}}"#)
        #expect(plan.configuration.mounts.count == 2)
        #expect(plan.configuration.mounts[0].isVirtiofs)
        #expect(plan.configuration.mounts[0].source == "/Users/me/src")
        #expect(plan.configuration.mounts[0].destination == "/src")
        #expect(plan.configuration.mounts[0].options == ["ro"])
        #expect(plan.configuration.mounts[1].options == [])
        #expect(plan.volumes == [DockerVolumeRequest(name: "data", destination: "/data")])
        #expect(plan.extras.anonymousVolumes.isEmpty)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["/a:/b:bogus"]}}"#) } == .badRequest("invalid mode: bogus"))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["/a"]}}"#) } == .badRequest("invalid volume specification: '/a'"))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["rel/dir:/b"]}}"#) }?.status == .badRequest)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["/a:b"]}}"#) }?.status == .badRequest)
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Binds":["/a:/x","/b:/x"]}}"#) } == .badRequest("Duplicate mount point: /x"))
    }

    @Test("--mount binds, volumes and tmpfs, and anonymous volumes from Volumes")
    func mounts() throws {
        let plan = try Fixtures.plan(
            #"""
            {"Image":"alpine","Volumes":{"/cache":{},"/src":{}},"HostConfig":{"Mounts":[
            {"Type":"bind","Source":"/Users/me/src","Target":"/src","ReadOnly":true},
            {"Type":"volume","Target":"/scratch"},
            {"Type":"tmpfs","Target":"/run","TmpfsOptions":{"SizeBytes":65536}}],
            "Tmpfs":{"/tmp":"size=64m,noexec"}}}
            """#)
        #expect(plan.configuration.mounts.map(\.destination) == ["/src", "/run", "/tmp"])
        #expect(plan.configuration.mounts[1].isTmpfs)
        #expect(plan.configuration.mounts[1].options == ["size=65536"])
        #expect(plan.configuration.mounts[2].options == ["size=64m", "noexec"])
        // `/src` is bound already, so only `/cache` gets a volume of its own.
        #expect(
            plan.volumes == [
                DockerVolumeRequest(name: "anon1", destination: "/scratch", anonymous: true),
                DockerVolumeRequest(name: "anon2", destination: "/cache", anonymous: true),
            ])
        #expect(plan.extras.anonymousVolumes == ["anon1", "anon2"])
        #expect(plan.extras.volumes == ["/cache", "/src"])
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Mounts":[{"Type":"bind","Source":"src","Target":"/s"}]}}"#) }?.status == .badRequest)
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"Mounts":[{"Type":"npipe","Target":"/p"}]}}"#) }
                == .badRequest("mount type \"npipe\" is not supported"))
    }

    @Test("ports: an empty host port takes a free one, a host IP and udp are kept, PublishAllPorts publishes exposed ports")
    func ports() throws {
        let plan = try Fixtures.plan(
            #"{"Image":"alpine","ExposedPorts":{"9000/tcp":{}},"HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"","HostPort":""}],"53/udp":[{"HostIp":"127.0.0.1","HostPort":"5353"}]},"PublishAllPorts":true}}"#
        )
        let ports = plan.configuration.publishedPorts.map { "\($0.hostAddress):\($0.hostPort)->\($0.containerPort)/\($0.proto.rawValue)" }
        #expect(ports == ["127.0.0.1:5353->53/udp", "0.0.0.0:40001->80/tcp", "0.0.0.0:40002->9000/tcp"])
        #expect(plan.extras.exposedPorts == ["53/udp", "80/tcp", "9000/tcp"])
        // Control: an exposed port alone is not published.
        #expect(try Fixtures.plan(#"{"Image":"alpine","ExposedPorts":{"9000/tcp":{}}}"#).configuration.publishedPorts.isEmpty)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"PortBindings":{"80/sctp":[{"HostPort":"80"}]}}}"#) } == .badRequest("invalid proto: sctp"))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"x"}]}}}"#) } == .badRequest("invalid host port: x"))
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"alpine","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}],"81/tcp":[{"HostPort":"8080"}]}}}"#) }?
                .status == .badRequest)
    }

    @Test("restart policies in Docker's spellings, and AutoRemove only without one")
    func restartPolicies() throws {
        #expect(try Fixtures.plan(#"{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"always"}}}"#).configuration.restartPolicy == .always)
        #expect(try Fixtures.plan(#"{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}}}"#).configuration.restartPolicy == .unlessStopped)
        #expect(
            try Fixtures.plan(#"{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3}}}"#).configuration.restartPolicy
                == .onFailure(maxRetries: 3))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"sometimes"}}}"#) }?.status == .badRequest)
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"always","MaximumRetryCount":2}}}"#) }
                == .badRequest("invalid restart policy: maximum retry count can only be used with 'on-failure'"))
        #expect(
            errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"AutoRemove":true,"RestartPolicy":{"Name":"always"}}}"#) }
                == .badRequest("can't create 'AutoRemove' container with restart policy"))
        // Control: AutoRemove with no policy is `--rm`.
        let removed = try Fixtures.plan(#"{"Image":"a","HostConfig":{"AutoRemove":true,"RestartPolicy":{"Name":"no"}}}"#)
        #expect(removed.autoRemove)
        #expect(removed.configuration.restartPolicy == nil)
    }

    @Test("CPUs round up to whole ones, memory is in bytes with Docker's minimum")
    func resources() throws {
        #expect(try Fixtures.plan(#"{"Image":"a","HostConfig":{"NanoCpus":1500000000}}"#).configuration.resources.cpus == 2)
        #expect(try Fixtures.plan(#"{"Image":"a","HostConfig":{"CpuCount":3}}"#).configuration.resources.cpus == 3)
        #expect(try Fixtures.plan(#"{"Image":"a","HostConfig":{"Memory":536870912}}"#).configuration.resources.memoryInBytes == 536_870_912)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"Memory":1024}}"#) } == .badRequest("Minimum memory limit allowed is 6MB"))
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"NanoCpus":1000000000,"CpuCount":2}}"#) }?.status == .badRequest)
    }

    @Test("extra hosts take host-gateway and either separator; a bad address is refused")
    func extraHosts() throws {
        let hosts = try Fixtures.plan(#"{"Image":"a","HostConfig":{"ExtraHosts":["host.docker.internal:host-gateway","db=10.0.0.5","v6:::1"]}}"#)
            .configuration.extraHosts
        #expect(hosts.map(\.name) == ["host.docker.internal", "db", "v6"])
        #expect(hosts.map(\.address) == ["host-gateway", "10.0.0.5", "::1"])
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"a","HostConfig":{"ExtraHosts":["db:nowhere"]}}"#) }?.status == .badRequest)
    }

    @Test("hostname, sysctls, read-only, init, capabilities, shm, DNS and Rosetta")
    func placement() throws {
        let plan = try Fixtures.plan(
            #"""
            {"Image":"a","Hostname":"box","Domainname":"lan","HostConfig":{"Sysctls":{"net.ipv4.ip_forward":"1"},"ReadonlyRootfs":true,"Init":true,
            "CapAdd":["net_admin","CAP_SYS_TIME"],"CapDrop":["all"],"ShmSize":134217728,"Dns":["9.9.9.9"],"DnsSearch":["corp"],"DnsOptions":["ndots:2"]}}
            """#, image: Fixtures.image(architecture: "amd64"))
        let configuration = plan.configuration
        #expect(configuration.hostname == "box")
        #expect(configuration.sysctls == ["net.ipv4.ip_forward": "1"])
        #expect(configuration.readOnly)
        #expect(configuration.useInit)
        #expect(configuration.capAdd == ["CAP_NET_ADMIN", "CAP_SYS_TIME"])
        #expect(configuration.capDrop == ["ALL"])
        #expect(configuration.shmSize == 134_217_728)
        #expect(configuration.dns?.nameservers == ["9.9.9.9"])
        #expect(configuration.dns?.domain == "lan")
        #expect(configuration.dns?.searchDomains == ["corp"])
        #expect(configuration.dns?.options == ["ndots:2"])
        #expect(configuration.rosetta)
        #expect(errorMessage { _ = try Fixtures.plan(#"{"Image":"a","Hostname":"not_a_label"}"#) }?.status == .badRequest)
        // Control: an arm64 image on an arm64 host needs no Rosetta, and the engine's DNS domain fills in.
        var defaults = Fixtures.defaults
        defaults.dnsDomain = "test"
        let plain = try Fixtures.plan(#"{"Image":"a"}"#, defaults: defaults).configuration
        #expect(!plain.rosetta)
        #expect(plain.dns?.domain == "test")
        #expect(plain.networks.first?.options.hostname == "abcdef012345.test.")
    }
}
