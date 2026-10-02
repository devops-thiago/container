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

import Foundation

// Reading one compose file into what it says, key by key. Every key compose defines is
// either read here or listed in a table that says why it is not, so that a key this code
// has never heard of can be told apart from one the engine cannot honour.

extension MappingReader {
    /// The value under `key`, decoded, or nil when the key is absent or its value is not
    /// what the key takes (which `decode` has reported).
    mutating func value<T>(_ key: String, _ decode: (ComposeNode, String) -> T?) -> T? {
        guard let node = take(key) else { return nil }
        return decode(node, path(of: key))
    }
}

extension DecodeContext {
    private static let virtualMachine = "each container runs in its own virtual machine, where only the cpus and memory limits apply"

    private static let topLevelKeys: [String: KeySupport] = [
        "configs": .rejected("mount a folder that holds the file, or pass the value in environment"),
        "secrets": .rejected("mount a folder that holds the file, or pass the value in environment"),
        "include": .rejected("name each file with -f instead"),
        "models": .rejected(""),
    ]

    private static let serviceKeys: [String: KeySupport] = [
        "annotations": .ignored("containers carry labels, not annotations"),
        "attach": .ignored("up follows every service's output"),
        "blkio_config": .ignored(virtualMachine),
        "cgroup_parent": .ignored(virtualMachine),
        "cpu_count": .ignored(virtualMachine),
        "cpu_percent": .ignored(virtualMachine),
        "cpu_period": .ignored(virtualMachine),
        "cpu_quota": .ignored(virtualMachine),
        "cpu_rt_period": .ignored(virtualMachine),
        "cpu_rt_runtime": .ignored(virtualMachine),
        "cpu_shares": .ignored(virtualMachine),
        "cpuset": .ignored(virtualMachine),
        "develop": .ignored("watching files for changes is not available"),
        "domainname": .ignored("a container has a hostname and no NIS domain"),
        "driver_opts": .ignored("there are no driver options to set"),
        "expose": .ignored("containers on a network reach every port of each other"),
        "external_links": .ignored("containers on a network find each other by service name"),
        "group_add": .ignored("supplementary groups are not set"),
        "isolation": .ignored("it applies to Windows containers"),
        "label_file": .ignored("labels are read from the labels key"),
        "links": .ignored("containers on a network find each other by service name"),
        "logging": .ignored("the engine keeps one log per container, which logs reads"),
        "mem_reservation": .ignored(virtualMachine),
        "mem_swappiness": .ignored(virtualMachine),
        "memswap_limit": .ignored(virtualMachine),
        "oom_kill_disable": .ignored(virtualMachine),
        "oom_score_adj": .ignored(virtualMachine),
        "pids_limit": .ignored(virtualMachine),
        "pull_refresh_after": .ignored("images are pulled as pull_policy says"),
        "security_opt": .ignored("a container is confined by its own virtual machine"),
        "stdin_open": .ignored("a detached container has no standard input to keep open"),
        "storage_opt": .ignored("there are no storage driver options to set"),

        "cgroup": .rejected("a container has its own kernel and control groups"),
        "configs": .rejected("mount a folder that holds the file, or pass the value in environment"),
        "credential_spec": .rejected(""),
        "device_cgroup_rules": .rejected("host devices are not passed to containers"),
        "devices": .rejected("host devices are not passed to containers"),
        "extends": .rejected("merge files with -f, or share settings with a YAML anchor"),
        "gpus": .rejected("host devices are not passed to containers"),
        "ipc": .rejected("a container has its own kernel and namespaces"),
        "models": .rejected(""),
        "network_mode": .rejected("a container attaches to networks; the host's, none, and another container's are not available"),
        "pid": .rejected("a container has its own kernel and namespaces"),
        "post_start": .rejected("lifecycle hooks are not run"),
        "pre_stop": .rejected("lifecycle hooks are not run"),
        "provider": .rejected(""),
        "runtime": .rejected(""),
        "secrets": .rejected("mount a folder that holds the file, or pass the value in environment"),
        "use_api_socket": .rejected(""),
        "userns_mode": .rejected("a container has its own kernel and namespaces"),
        "uts": .rejected("a container has its own kernel and namespaces"),
        "volumes_from": .rejected("name the volumes in each service that mounts them"),
    ]

    private static let buildKeys: [String: KeySupport] = [
        "cache_from": .ignored("the builder keeps its own cache"),
        "cache_to": .ignored("the builder keeps its own cache"),
        "entitlements": .ignored("builds run without extra entitlements"),
        "extra_hosts": .ignored("the builder resolves names on its own network"),
        "isolation": .ignored("it applies to Windows containers"),
        "network": .ignored("the builder uses its own network"),
        "privileged": .ignored("builds run unprivileged"),
        "provenance": .ignored("attestations are not produced"),
        "pull": .ignored("base images are pulled when they are missing"),
        "sbom": .ignored("attestations are not produced"),
        "shm_size": .ignored("the builder sets its own shared memory size"),
        "tags": .ignored("the image is tagged with the service's image name"),
        "ulimits": .ignored("the builder sets its own limits"),

        "additional_contexts": .rejected("a build has one context"),
        "dockerfile_inline": .rejected("write the Dockerfile to a file and name it with dockerfile"),
        "secrets": .rejected("pass build-time values with args"),
        "ssh": .rejected(""),
    ]

    private static let deployKeys: [String: KeySupport] = [
        "endpoint_mode": .ignored("it applies to a swarm"),
        "labels": .ignored("it applies to a swarm"),
        "mode": .ignored("it applies to a swarm"),
        "placement": .ignored("it applies to a swarm"),
        "restart_policy": .ignored("it applies to a swarm; restart sets the container's policy"),
        "rollback_config": .ignored("it applies to a swarm"),
        "update_config": .ignored("it applies to a swarm"),
    ]

    private static let networkKeys: [String: KeySupport] = [
        "attachable": .ignored("any container can attach to a network"),
        "driver_opts": .ignored("there are no driver options to set"),
        "enable_ipv4": .ignored("a network always has an IPv4 subnet"),
        "enable_ipv6": .ignored("an IPv6 prefix is assigned when the host has one"),
    ]

    private static let volumeKeys: [String: KeySupport] = [
        "driver_opts": .ignored("a volume is a disk image the engine sizes")
    ]

    // MARK: Project

    func project(_ root: ComposeNode) -> RawProject {
        var project = RawProject()
        guard var reader = MappingReader(root, path: "", diagnostics: diagnostics) else { return project }
        project.name = reader.value("name", text)
        // `version` meant something to Compose v1 and is accepted and unused since.
        _ = reader.take("version")

        if let services = reader.take("services"), let entries = named(services, "services") {
            for entry in entries {
                project.services[entry.key] = service(entry.value, name: entry.key, at: entry.keyLocation)
            }
        }
        if let networks = reader.take("networks"), let entries = named(networks, "networks") {
            for entry in entries {
                project.networks[entry.key] = network(entry.value, key: entry.key)
            }
        }
        if let volumes = reader.take("volumes"), let entries = named(volumes, "volumes") {
            for entry in entries {
                project.volumes[entry.key] = volume(entry.value, key: entry.key)
            }
        }
        reader.finish(known: Self.topLevelKeys)
        return project
    }

    /// The entries of a mapping whose keys are names the file chose.
    private func named(_ node: ComposeNode, _ path: String) -> [ComposeNode.Entry]? {
        guard let reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        return reader.all.filter { !$0.key.hasPrefix("x-") }
    }

    // MARK: Service

    func service(_ node: ComposeNode, name: String, at location: SourceLocation) -> RawService {
        var service = RawService()
        service.location = location
        guard var reader = MappingReader(node, path: "services.\(name)", diagnostics: diagnostics) else { return service }
        service.keyLocations = reader.keyLocations

        service.image = reader.value("image", text)
        service.build = reader.value("build", build)
        service.command = reader.value("command", command)
        service.entrypoint = reader.value("entrypoint", command)
        service.environment = reader.value("environment", pairs).map { pairs in
            Dictionary(pairs.map { ($0.key, $0.value) }) { _, later in later }
        }
        service.envFiles = reader.value("env_file", envFiles)
        service.ports = reader.value("ports", ports)
        service.mounts = reader.value("volumes", mounts)
        service.dependsOn = reader.value("depends_on", dependencies)
        if let node = reader.take("healthcheck") {
            service.healthcheck = healthcheck(node, reader.path(of: "healthcheck"))
        }
        service.restart = reader.value("restart", restartPolicy)
        service.containerName = reader.value("container_name", text)
        service.networks = reader.value("networks", serviceNetworks)
        service.profiles = reader.value("profiles") { texts($0, $1) }
        service.pullPolicy = reader.value("pull_policy", pullPolicy)
        service.workingDirectory = reader.value("working_dir", text)
        service.user = reader.value("user", text)
        service.labels = reader.value("labels", dictionary)
        service.platform = reader.value("platform", text)
        service.tmpfs = reader.value("tmpfs") { texts($0, $1) }
        service.ulimits = reader.value("ulimits", ulimits)
        service.capAdd = reader.value("cap_add") { texts($0, $1) }
        service.capDrop = reader.value("cap_drop") { texts($0, $1) }
        service.readOnly = reader.value("read_only", bool)
        service.useInit = reader.value("init", bool)
        service.tty = reader.value("tty", bool)
        service.shmSize = reader.value("shm_size", size)
        service.dns = reader.value("dns") { texts($0, $1) }
        service.dnsSearch = reader.value("dns_search") { texts($0, $1) }
        service.dnsOptions = reader.value("dns_opt") { texts($0, $1) }
        service.stopSignal = reader.value("stop_signal", text)
        service.stopGracePeriod = reader.value("stop_grace_period", duration)
        service.cpus = reader.value("cpus", number)
        service.memory = reader.value("mem_limit", size)
        service.sysctls = reader.value("sysctls", dictionary)
        service.hostname = reader.value("hostname", text)
        service.extraHosts = reader.value("extra_hosts", extraHosts)

        // A MAC address for the service is one for its first network.
        if let mac = reader.value("mac_address", text), var networks = service.networks, !networks.isEmpty,
            networks[0].macAddress == nil
        {
            networks[0].macAddress = mac
            service.networks = networks
        }

        if let node = reader.take("deploy") {
            deploy(node, reader.path(of: "deploy"), into: &service)
        }
        if let node = reader.take("scale"), let count = integer(node, reader.path(of: "scale")), count != 1 {
            diagnostics.error(
                reader.path(of: "scale"), "not supported on this engine: a service runs as one container", at: reader.keyLocation("scale"))
        }
        if let node = reader.take("privileged"), bool(node, reader.path(of: "privileged")) == true {
            diagnostics.error(
                reader.path(of: "privileged"),
                "not supported on this engine: a container already has its own kernel; add the capabilities it needs with cap_add",
                at: reader.keyLocation("privileged"))
        }
        reader.finish(known: Self.serviceKeys)
        return service
    }

    private func restartPolicy(_ node: ComposeNode, _ path: String) -> String? {
        guard let policy = text(node, path) else { return nil }
        let name = policy.split(separator: ":", maxSplits: 1).first.map(String.init) ?? policy
        let retries = policy.split(separator: ":", maxSplits: 1).dropFirst().first
        let valid = ["no", "always", "unless-stopped", "on-failure"].contains(name) && (retries == nil || (name == "on-failure" && Int(retries ?? "") != nil))
        guard valid else {
            diagnostics.error(path, "expected no, always, unless-stopped or on-failure[:retries], found '\(policy)'", at: node.location)
            return nil
        }
        return policy
    }

    private func pullPolicy(_ node: ComposeNode, _ path: String) -> ComposePullPolicy? {
        guard let policy = text(node, path) else { return nil }
        switch policy {
        case "always": return .always
        case "never": return .never
        case "missing", "if_not_present": return .missing
        case "build": return .build
        default:
            diagnostics.error(path, "expected always, never, missing or build, found '\(policy)'", at: node.location)
            return nil
        }
    }

    // MARK: Build

    private func build(_ node: ComposeNode, _ path: String) -> RawBuild? {
        var build = RawBuild()
        if let context = node.scalar {
            build.context = buildContext(context, path, at: node.location)
            return build
        }
        guard var reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        if let context = reader.take("context"), let text = text(context, reader.path(of: "context")) {
            build.context = buildContext(text, reader.path(of: "context"), at: context.location)
        }
        build.dockerfile = reader.value("dockerfile", text)
        build.args = reader.value("args", pairs).map { pairs in
            Dictionary(pairs.map { ($0.key, $0.value) }) { _, later in later }
        }
        build.target = reader.value("target", text)
        build.labels = reader.value("labels", dictionary)
        build.noCache = reader.value("no_cache", bool)
        build.platforms = reader.value("platforms") { texts($0, $1) }
        reader.finish(known: Self.buildKeys)
        return build
    }

    private func buildContext(_ context: String, _ path: String, at location: SourceLocation) -> String? {
        let remote = ["http://", "https://", "git://", "ssh://", "git@", "github.com/"].contains { context.hasPrefix($0) }
        guard !remote else {
            diagnostics.error(path, "not supported on this engine: a build context has to be a folder on this Mac", at: location)
            return nil
        }
        return absolute(context)
    }

    // MARK: Environment files

    private func envFiles(_ node: ComposeNode, _ path: String) -> [RawEnvFile]? {
        let items: [ComposeNode]
        switch node.value {
        case .sequence(let sequence): items = sequence
        case .scalar, .mapping: items = [node]
        case .null: return nil
        }
        var files: [RawEnvFile] = []
        for (index, item) in items.enumerated() {
            let itemPath = items.count == 1 && node.sequence == nil ? path : "\(path)[\(index)]"
            if let file = item.scalar {
                files.append(RawEnvFile(path: absolute(file), required: true, location: item.location))
                continue
            }
            guard var reader = MappingReader(item, path: itemPath, diagnostics: diagnostics) else { return nil }
            guard let file = reader.value("path", text) else {
                diagnostics.error(itemPath, "an env_file entry needs a path", at: item.location)
                return nil
            }
            let required = reader.value("required", bool) ?? true
            if let format = reader.take("format"), let name = text(format, reader.path(of: "format")), name != "dotenv" {
                diagnostics.error(
                    reader.path(of: "format"), "not supported on this engine: env files are read as KEY=value lines",
                    at: reader.keyLocation("format"))
            }
            reader.finish()
            files.append(RawEnvFile(path: absolute(file), required: required, location: item.location))
        }
        return files
    }

    // MARK: Ports

    private func ports(_ node: ComposeNode, _ path: String) -> [ComposePort]? {
        guard let items = node.sequence else {
            diagnostics.error(path, "expected a list, found \(node.kind)", at: node.location)
            return nil
        }
        var result: [ComposePort] = []
        for (index, item) in items.enumerated() {
            let itemPath = "\(path)[\(index)]"
            if let spec = item.scalar {
                guard let port = shortPort(spec, itemPath, at: item.location) else { continue }
                result.append(port)
                continue
            }
            guard var reader = MappingReader(item, path: itemPath, diagnostics: diagnostics) else { continue }
            let target = reader.value("target", text)
            let published = reader.value("published", text)
            let hostIP = reader.value("host_ip", text)
            let transport = reader.value("protocol", text) ?? "tcp"
            if let mode = reader.take("mode"), let name = text(mode, reader.path(of: "mode")), name != "host", name != "ingress" {
                diagnostics.error(reader.path(of: "mode"), "expected host or ingress, found '\(name)'", at: mode.location)
            }
            _ = reader.take("name")
            _ = reader.take("app_protocol")
            reader.finish()
            guard let target else {
                diagnostics.error(itemPath, "a port needs a target", at: item.location)
                continue
            }
            let spec =
                [hostIP.map(Self.bracketed), published ?? (hostIP == nil ? nil : ""), target]
                .compactMap { $0 }.joined(separator: ":") + "/" + transport
            if let port = shortPort(spec, itemPath, at: item.location) { result.append(port) }
        }
        return result
    }

    private static func bracketed(_ address: String) -> String {
        address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
    }

    /// `[host-ip:][host-port:]container-port[/protocol]`, either port a range.
    func shortPort(_ spec: String, _ path: String, at location: SourceLocation) -> ComposePort? {
        func fail(_ reason: String) -> ComposePort? {
            diagnostics.error(path, "'\(spec)' is not a port mapping: \(reason)", at: location)
            return nil
        }
        var rest = Substring(spec.trimmingCharacters(in: .whitespaces))
        var transport = ComposePort.Transport.tcp
        if let slash = rest.lastIndex(of: "/") {
            guard let named = ComposePort.Transport(rawValue: rest[rest.index(after: slash)...].lowercased()) else {
                return fail("the protocol is tcp or udp")
            }
            transport = named
            rest = rest[..<slash]
        }

        var hostIP: String?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return fail("the address in brackets is never closed") }
            hostIP = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            guard rest.hasPrefix(":") else { return fail("a host address is followed by ports") }
            rest = rest.dropFirst()
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let published: String?
        let target: String
        switch (parts.count, hostIP) {
        case (1, nil):
            (published, target) = (nil, parts[0])
        case (1, .some):
            return fail("a host address is followed by a host port and a container port")
        case (2, _):
            (published, target) = (parts[0].isEmpty ? nil : parts[0], parts[1])
        case (3, nil):
            hostIP = parts[0]
            (published, target) = (parts[1].isEmpty ? nil : parts[1], parts[2])
        default:
            return fail("it has too many parts; write an IPv6 address in brackets")
        }

        guard let targetRange = Self.portRange(target) else { return fail("'\(target)' is not a port or a range of ports") }
        if let published {
            guard let publishedRange = Self.portRange(published) else {
                return fail("'\(published)' is not a port or a range of ports")
            }
            guard publishedRange.count == targetRange.count else {
                return fail("the host and container ranges have to be the same size")
            }
        } else if targetRange.count > 1 {
            return fail("a range of container ports needs a range of host ports")
        }
        if let hostIP, hostIP.isEmpty { return fail("the host address is empty") }
        return ComposePort(hostIP: hostIP, published: published, target: target, transport: transport)
    }

    private static func portRange(_ text: String) -> ClosedRange<Int>? {
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(bounds.count),
            let low = Int(bounds[0]), let high = Int(bounds[bounds.count - 1]),
            (1...65535).contains(low), (1...65535).contains(high), low <= high
        else { return nil }
        return low...high
    }

    // MARK: Volumes

    private func mounts(_ node: ComposeNode, _ path: String) -> [ComposeMount]? {
        guard let items = node.sequence else {
            diagnostics.error(path, "expected a list, found \(node.kind)", at: node.location)
            return nil
        }
        var result: [ComposeMount] = []
        for (index, item) in items.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let mount = item.scalar.map { shortMount($0, itemPath, at: item.location) } ?? longMount(item, itemPath)
            if let mount { result.append(mount) }
        }
        return result
    }

    private static let mountModes: Set<String> = [
        "ro", "rw", "z", "Z", "cached", "delegated", "consistent", "nocopy",
        "shared", "rshared", "slave", "rslave", "private", "rprivate",
    ]

    /// `[source:]target[:mode]`. A source that looks like a path is a folder on this Mac;
    /// any other is the name of a volume.
    func shortMount(_ spec: String, _ path: String, at location: SourceLocation) -> ComposeMount? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var source: String?
        var target: String
        var modes: [String] = []
        switch parts.count {
        case 1:
            target = parts[0]
        case 2 where parts[1].split(separator: ",").allSatisfy({ Self.mountModes.contains(String($0)) }) && !parts[1].isEmpty:
            target = parts[0]
            modes = parts[1].split(separator: ",").map(String.init)
        case 2:
            (source, target) = (parts[0], parts[1])
        case 3:
            (source, target) = (parts[0], parts[1])
            modes = parts[2].split(separator: ",").map(String.init)
        default:
            diagnostics.error(path, "'\(spec)' is not a volume: expected [source:]target[:mode]", at: location)
            return nil
        }
        if let unknown = modes.first(where: { !Self.mountModes.contains($0) }) {
            diagnostics.error(path, "'\(spec)' is not a volume: '\(unknown)' is not a mount option", at: location)
            return nil
        }
        guard target.hasPrefix("/") else {
            diagnostics.error(path, "'\(spec)' is not a volume: the path in the container has to be absolute", at: location)
            return nil
        }
        target = Self.withoutTrailingSlash(target)
        let readOnly = modes.contains("ro")
        guard let source, !source.isEmpty else {
            return ComposeMount(kind: .anonymous, target: target, readOnly: readOnly)
        }
        let isPath = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
        return ComposeMount(kind: isPath ? .bind(source: absolute(source)) : .volume(key: source), target: target, readOnly: readOnly)
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func longMount(_ node: ComposeNode, _ path: String) -> ComposeMount? {
        guard var reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        let kind = reader.value("type", text) ?? "volume"
        let source = reader.value("source", text)
        let target = reader.value("target", text)
        let readOnly = reader.value("read_only", bool) ?? false
        _ = reader.take("consistency")
        var tmpfsSize: String?
        if let bind = reader.take("bind"), var options = MappingReader(bind, path: reader.path(of: "bind"), diagnostics: diagnostics) {
            _ = options.take("create_host_path")
            _ = options.take("propagation")
            _ = options.take("selinux")
            options.finish()
        }
        if let volume = reader.take("volume"), var options = MappingReader(volume, path: reader.path(of: "volume"), diagnostics: diagnostics) {
            _ = options.take("nocopy")
            if options.take("subpath") != nil {
                diagnostics.error(
                    options.path(of: "subpath"), "not supported on this engine: a volume is mounted whole", at: options.keyLocation("subpath"))
            }
            options.finish()
        }
        if let tmpfs = reader.take("tmpfs"), var options = MappingReader(tmpfs, path: reader.path(of: "tmpfs"), diagnostics: diagnostics) {
            tmpfsSize = options.value("size", size)
            _ = options.take("mode")
            options.finish()
        }
        reader.finish()

        guard let target, target.hasPrefix("/") else {
            diagnostics.error(path, "a volume needs a target: an absolute path in the container", at: node.location)
            return nil
        }
        let destination = Self.withoutTrailingSlash(target)
        switch kind {
        case "bind":
            guard let source, !source.isEmpty else {
                diagnostics.error(path, "a bind mount needs a source", at: node.location)
                return nil
            }
            return ComposeMount(kind: .bind(source: absolute(source)), target: destination, readOnly: readOnly)
        case "volume":
            guard let source, !source.isEmpty else {
                return ComposeMount(kind: .anonymous, target: destination, readOnly: readOnly)
            }
            return ComposeMount(kind: .volume(key: source), target: destination, readOnly: readOnly)
        case "tmpfs":
            return ComposeMount(kind: .tmpfs(size: tmpfsSize), target: destination, readOnly: readOnly)
        default:
            diagnostics.error(reader.path(of: "type"), "not supported on this engine: a mount is a bind, a volume or a tmpfs", at: node.location)
            return nil
        }
    }

    // MARK: Dependencies

    private func dependencies(_ node: ComposeNode, _ path: String) -> [ComposeDependency]? {
        if let names = node.sequence {
            return names.enumerated().compactMap { index, item in
                text(item, "\(path)[\(index)]").map { ComposeDependency(service: $0) }
            }
        }
        guard let reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        var result: [ComposeDependency] = []
        for entry in reader.all {
            var dependency = ComposeDependency(service: entry.key)
            guard var options = MappingReader(entry.value, path: reader.path(of: entry.key), diagnostics: diagnostics) else { continue }
            if let condition = options.take("condition"), let name = text(condition, options.path(of: "condition")) {
                guard let known = ComposeDependency.Condition(rawValue: name) else {
                    diagnostics.error(
                        options.path(of: "condition"),
                        "expected service_started, service_healthy or service_completed_successfully, found '\(name)'",
                        at: condition.location)
                    continue
                }
                dependency.condition = known
            }
            dependency.required = options.value("required", bool) ?? true
            dependency.restart = options.value("restart", bool) ?? false
            options.finish()
            result.append(dependency)
        }
        return result
    }

    // MARK: Healthcheck

    private func healthcheck(_ node: ComposeNode, _ path: String) -> RawHealthcheck? {
        guard var reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        var check = RawHealthcheck()
        check.location = node.location
        check.disable = reader.value("disable", bool)
        check.interval = reader.value("interval", duration)
        check.timeout = reader.value("timeout", duration)
        check.retries = reader.value("retries", integer)
        check.startPeriod = reader.value("start_period", duration)
        check.startInterval = reader.value("start_interval", duration)
        if let test = reader.take("test") {
            let testPath = reader.path(of: "test")
            if let shell = test.scalar {
                check.test = ["/bin/sh", "-c", shell]
            } else if let words = texts(test, testPath, allowingSingle: false) {
                switch words.first {
                case "NONE":
                    check.disable = true
                case "CMD" where words.count > 1:
                    check.test = Array(words.dropFirst())
                case "CMD-SHELL" where words.count == 2:
                    check.test = ["/bin/sh", "-c", words[1]]
                default:
                    diagnostics.error(
                        testPath, "a test written as a list starts with CMD and a command, CMD-SHELL and one string, or NONE",
                        at: test.location)
                }
            }
        }
        reader.finish()
        return check
    }

    // MARK: Networks of a service

    private func serviceNetworks(_ node: ComposeNode, _ path: String) -> [ComposeServiceNetwork]? {
        if let names = node.sequence {
            return names.enumerated().compactMap { index, item in
                text(item, "\(path)[\(index)]").map { ComposeServiceNetwork(key: $0) }
            }
        }
        guard let reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        var result: [ComposeServiceNetwork] = []
        for entry in reader.all {
            var network = ComposeServiceNetwork(key: entry.key)
            guard var options = MappingReader(entry.value, path: reader.path(of: entry.key), diagnostics: diagnostics) else { continue }
            network.aliases = options.value("aliases") { texts($0, $1) } ?? []
            network.macAddress = options.value("mac_address", text)
            for key in ["ipv4_address", "ipv6_address"] where options.take(key) != nil {
                diagnostics.error(
                    options.path(of: key),
                    "not supported on this engine: the network gives a container its address, which it keeps until it is removed",
                    at: options.keyLocation(key))
            }
            options.finish(known: [
                "driver_opts": .ignored("there are no driver options to set"),
                "gw_priority": .ignored("a container's default route is its first network's"),
                "interface_name": .ignored("interfaces are named by the container's kernel"),
                "link_local_ips": .ignored("link-local addresses are not assigned"),
                "priority": .ignored("networks attach in the order they are listed"),
            ])
            result.append(network)
        }
        return result
    }

    // MARK: Limits

    private func ulimits(_ node: ComposeNode, _ path: String) -> [ComposeUlimit]? {
        guard let reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return nil }
        var result: [ComposeUlimit] = []
        for entry in reader.all {
            let entryPath = reader.path(of: entry.key)
            if let both = entry.value.scalar {
                result.append(ComposeUlimit(name: entry.key, soft: both))
                continue
            }
            guard var limits = MappingReader(entry.value, path: entryPath, diagnostics: diagnostics) else { continue }
            let soft = limits.value("soft", text)
            let hard = limits.value("hard", text)
            limits.finish()
            guard let soft = soft ?? hard else {
                diagnostics.error(entryPath, "a limit is one number, or soft and hard", at: entry.value.location)
                continue
            }
            result.append(ComposeUlimit(name: entry.key, soft: soft, hard: hard))
        }
        return result
    }

    private func deploy(_ node: ComposeNode, _ path: String, into service: inout RawService) {
        guard var reader = MappingReader(node, path: path, diagnostics: diagnostics) else { return }
        if let replicas = reader.take("replicas"), let count = integer(replicas, reader.path(of: "replicas")), count != 1 {
            diagnostics.error(
                reader.path(of: "replicas"), "not supported on this engine: a service runs as one container", at: reader.keyLocation("replicas"))
        }
        if let resources = reader.take("resources"),
            var resourceReader = MappingReader(resources, path: reader.path(of: "resources"), diagnostics: diagnostics)
        {
            if let limits = resourceReader.take("limits"),
                var limitReader = MappingReader(limits, path: resourceReader.path(of: "limits"), diagnostics: diagnostics)
            {
                if let cpus = limitReader.value("cpus", number) { service.cpus = cpus }
                if let memory = limitReader.value("memory", size) { service.memory = memory }
                limitReader.finish(known: ["pids": .ignored(Self.virtualMachine)])
            }
            resourceReader.finish(known: ["reservations": .ignored(Self.virtualMachine)])
        }
        reader.finish(known: Self.deployKeys)
    }

    // MARK: Extra hosts

    /// `name:address` pairs from a list (`name:address` or `name=address`) or a mapping.
    private func extraHosts(_ node: ComposeNode, _ path: String) -> [String]? {
        func pair(_ name: String, _ address: String) -> String {
            var address = address.trimmingCharacters(in: .whitespaces)
            if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
            return "\(name.trimmingCharacters(in: .whitespaces)):\(address)"
        }
        switch node.value {
        case .mapping(let entries):
            var result: [String] = []
            for entry in entries {
                guard let addresses = texts(entry.value, "\(path).\(entry.key)") else { return nil }
                result.append(contentsOf: addresses.map { pair(entry.key, $0) })
            }
            return result
        case .sequence:
            guard let items = texts(node, path) else { return nil }
            var result: [String] = []
            for item in items {
                guard let separator = item.firstIndex(of: "=") ?? item.firstIndex(of: ":") else {
                    diagnostics.error(path, "'\(item)' is not a host: expected name:address", at: node.location)
                    return nil
                }
                result.append(pair(String(item[..<separator]), String(item[item.index(after: separator)...])))
            }
            return result
        default:
            diagnostics.error(path, "expected a list of name:address or a mapping, found \(node.kind)", at: node.location)
            return nil
        }
    }

    // MARK: Top-level networks and volumes

    func network(_ node: ComposeNode, key: String) -> RawNetwork {
        var network = RawNetwork()
        network.location = node.location
        guard var reader = MappingReader(node, path: "networks.\(key)", diagnostics: diagnostics) else { return network }
        network.name = reader.value("name", text)
        network.isInternal = reader.value("internal", bool)
        network.labels = reader.value("labels", dictionary)
        (network.external, network.name) = external(&reader, name: network.name)
        if let driver = reader.take("driver"), let name = text(driver, reader.path(of: "driver")), name != "bridge" {
            diagnostics.error(
                reader.path(of: "driver"), "not supported on this engine: networks are of one kind, which compose calls bridge",
                at: reader.keyLocation("driver"))
        }
        if let ipam = reader.take("ipam"), var ipamReader = MappingReader(ipam, path: reader.path(of: "ipam"), diagnostics: diagnostics) {
            if let driver = ipamReader.take("driver"), let name = text(driver, ipamReader.path(of: "driver")), name != "default" {
                diagnostics.error(
                    ipamReader.path(of: "driver"), "not supported on this engine: addresses come from the network itself",
                    at: ipamReader.keyLocation("driver"))
            }
            if let config = ipamReader.take("config") {
                let configPath = ipamReader.path(of: "config")
                let pools = config.sequence ?? []
                if config.sequence == nil {
                    diagnostics.error(configPath, "expected a list, found \(config.kind)", at: config.location)
                }
                var subnets: [String] = []
                for (index, pool) in pools.enumerated() {
                    guard var poolReader = MappingReader(pool, path: "\(configPath)[\(index)]", diagnostics: diagnostics) else { continue }
                    if let subnet = poolReader.value("subnet", text) { subnets.append(subnet) }
                    poolReader.finish(known: [
                        "aux_addresses": .ignored("addresses are not reserved by name"),
                        "gateway": .ignored("the gateway is the first address of the subnet"),
                        "ip_range": .ignored("containers get addresses from the whole subnet"),
                    ])
                }
                let ipv4 = subnets.filter { !$0.contains(":") }
                if ipv4.count > 1 {
                    diagnostics.error(configPath, "not supported on this engine: a network has one IPv4 subnet", at: config.location)
                }
                if subnets.contains(where: { $0.contains(":") }) {
                    diagnostics.warn(configPath, "ignored: an IPv6 prefix is assigned when the host has one", at: config.location)
                }
                network.subnet = ipv4.first
            }
            ipamReader.finish(known: ["options": .ignored("there are no address-management options to set")])
        }
        reader.finish(known: Self.networkKeys)
        return network
    }

    func volume(_ node: ComposeNode, key: String) -> RawVolume {
        var volume = RawVolume()
        volume.location = node.location
        guard var reader = MappingReader(node, path: "volumes.\(key)", diagnostics: diagnostics) else { return volume }
        volume.name = reader.value("name", text)
        volume.labels = reader.value("labels", dictionary)
        (volume.external, volume.name) = external(&reader, name: volume.name)
        if let driver = reader.take("driver"), let name = text(driver, reader.path(of: "driver")), name != "local" {
            diagnostics.error(
                reader.path(of: "driver"), "not supported on this engine: volumes are local disk images", at: reader.keyLocation("driver"))
        }
        reader.finish(known: Self.volumeKeys)
        return volume
    }

    /// `external: true`, or the older `external: { name: actual }`.
    private func external(_ reader: inout MappingReader, name: String?) -> (Bool?, String?) {
        guard let node = reader.take("external") else { return (nil, name) }
        if node.scalar != nil {
            return (bool(node, reader.path(of: "external")), name)
        }
        guard var options = MappingReader(node, path: reader.path(of: "external"), diagnostics: diagnostics) else { return (nil, name) }
        let actual = options.value("name", text)
        options.finish()
        return (true, actual ?? name)
    }
}
