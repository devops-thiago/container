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
import Yams

extension ComposeDefinition {
    /// The project as one compose file: the files merged, their variables substituted, and
    /// every short form spelled out. Reading it back gives the same project.
    ///
    /// A part in `unread` is left out. What is wrong with it is not in the model, so written
    /// from the model it would read back as a part with nothing wrong.
    public func yaml() throws -> String {
        let left = Set(unread.map(\.part))
        let services = file.services.filter { !left.contains(.service($0.name)) }
        let networks = file.networks.filter { !left.contains(.network($0.key)) }
        let volumes = file.volumes.filter { !left.contains(.volume($0.key)) }
        var root: [String: Any] = ["name": name]
        root["services"] = Dictionary(uniqueKeysWithValues: services.map { ($0.name, Self.node(for: $0) as Any) })
        if !networks.isEmpty {
            root["networks"] = Dictionary(uniqueKeysWithValues: networks.map { ($0.key, Self.node(for: $0) as Any) })
        }
        if !volumes.isEmpty {
            root["volumes"] = Dictionary(uniqueKeysWithValues: volumes.map { ($0.key, Self.node(for: $0) as Any) })
        }
        return try Yams.dump(object: Self.prepared(root), indent: 2, width: -1, allowUnicode: true)
    }

    /// A mapping whose keys stay in the order given. A service's networks are one: the
    /// first is the one its own name belongs to.
    private struct OrderedMapping: NodeRepresentable {
        let entries: [(key: String, value: Any)]

        func represented() throws -> Node {
            let pairs = try entries.map { entry -> (Node, Node) in
                guard let value = entry.value as? NodeRepresentable else {
                    throw ComposeError("the value of \(entry.key) cannot be written as YAML")
                }
                return (try entry.key.represented(), try value.represented())
            }
            return Node.mapping(Node.Mapping(pairs))
        }
    }

    /// The tree ready to be written: mappings in key order, so that the output does not
    /// change from run to run, and every dollar sign in a value doubled, so that reading
    /// the file back does not take what is now plain text for a variable.
    private static func prepared(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return text.replacingOccurrences(of: "$", with: "$$")
        case let list as [Any]:
            return list.map(prepared)
        case let map as [String: Any]:
            return OrderedMapping(entries: map.keys.sorted().map { ($0, prepared(map[$0] as Any)) })
        case let ordered as OrderedMapping:
            return OrderedMapping(entries: ordered.entries.map { ($0.key, prepared($0.value)) })
        default:
            return value
        }
    }

    private static func node(for service: ComposeService) -> [String: Any] {
        var node: [String: Any] = [:]
        node["image"] = service.image
        if let build = service.build {
            var buildNode: [String: Any] = ["context": build.context]
            buildNode["dockerfile"] = build.dockerfile
            buildNode["target"] = build.target
            if !build.args.isEmpty { buildNode["args"] = build.args }
            if !build.labels.isEmpty { buildNode["labels"] = build.labels }
            if build.noCache { buildNode["no_cache"] = true }
            if !build.platforms.isEmpty { buildNode["platforms"] = build.platforms }
            node["build"] = buildNode
        }
        node["command"] = service.command
        node["entrypoint"] = service.entrypoint
        if !service.environment.isEmpty { node["environment"] = service.environment }
        if !service.ports.isEmpty {
            node["ports"] = service.ports.map { port -> [String: Any] in
                var portNode: [String: Any] = ["target": port.target, "protocol": port.transport.rawValue]
                portNode["published"] = port.published
                portNode["host_ip"] = port.hostIP
                return portNode
            }
        }
        if !service.mounts.isEmpty {
            node["volumes"] = service.mounts.map { mount -> [String: Any] in
                var mountNode: [String: Any] = ["target": mount.target]
                switch mount.kind {
                case .bind(let source):
                    mountNode["type"] = "bind"
                    mountNode["source"] = source
                case .volume(let key):
                    mountNode["type"] = "volume"
                    mountNode["source"] = key
                case .anonymous:
                    mountNode["type"] = "volume"
                case .tmpfs(let size):
                    mountNode["type"] = "tmpfs"
                    if let size { mountNode["tmpfs"] = ["size": size] }
                }
                if mount.readOnly { mountNode["read_only"] = true }
                return mountNode
            }
        }
        if !service.dependsOn.isEmpty {
            node["depends_on"] = Dictionary(
                uniqueKeysWithValues: service.dependsOn.map { dependency -> (String, Any) in
                    var dependencyNode: [String: Any] = ["condition": dependency.condition.rawValue]
                    if !dependency.required { dependencyNode["required"] = false }
                    if dependency.restart { dependencyNode["restart"] = true }
                    return (dependency.service, dependencyNode)
                })
        }
        if let check = service.healthcheck {
            var checkNode: [String: Any] = [:]
            if check.isDisabled {
                checkNode["disable"] = true
            } else {
                if !check.test.isEmpty { checkNode["test"] = ["CMD"] + check.test }
                if let interval = check.interval { checkNode["interval"] = duration(interval) }
                if let timeout = check.timeout { checkNode["timeout"] = duration(timeout) }
                if let retries = check.retries { checkNode["retries"] = retries }
                if let startPeriod = check.startPeriod { checkNode["start_period"] = duration(startPeriod) }
                if let startInterval = check.startInterval { checkNode["start_interval"] = duration(startInterval) }
            }
            node["healthcheck"] = checkNode
        }
        node["restart"] = service.restart
        node["container_name"] = service.containerName
        if !service.networks.isEmpty {
            node["networks"] = OrderedMapping(
                entries: service.networks.map { network -> (key: String, value: Any) in
                    var networkNode: [String: Any] = [:]
                    if !network.aliases.isEmpty { networkNode["aliases"] = network.aliases }
                    networkNode["mac_address"] = network.macAddress
                    return (network.key, networkNode)
                })
        }
        if !service.profiles.isEmpty { node["profiles"] = service.profiles }
        node["pull_policy"] = service.pullPolicy?.rawValue
        node["working_dir"] = service.workingDirectory
        node["user"] = service.user
        if !service.labels.isEmpty { node["labels"] = service.labels }
        node["platform"] = service.platform
        if !service.tmpfs.isEmpty { node["tmpfs"] = service.tmpfs }
        if !service.ulimits.isEmpty {
            node["ulimits"] = Dictionary(
                uniqueKeysWithValues: service.ulimits.map { limit -> (String, Any) in
                    guard let hard = limit.hard else { return (limit.name, limit.soft) }
                    return (limit.name, ["soft": limit.soft, "hard": hard])
                })
        }
        if !service.capAdd.isEmpty { node["cap_add"] = service.capAdd }
        if !service.capDrop.isEmpty { node["cap_drop"] = service.capDrop }
        if service.readOnly { node["read_only"] = true }
        if service.useInit { node["init"] = true }
        if service.tty { node["tty"] = true }
        node["shm_size"] = service.shmSize
        if !service.dns.isEmpty { node["dns"] = service.dns }
        if !service.dnsSearch.isEmpty { node["dns_search"] = service.dnsSearch }
        if !service.dnsOptions.isEmpty { node["dns_opt"] = service.dnsOptions }
        node["stop_signal"] = service.stopSignal
        node["stop_grace_period"] = service.stopGracePeriod.map(duration)
        node["cpus"] = service.cpus
        node["mem_limit"] = service.memory
        if !service.sysctls.isEmpty { node["sysctls"] = service.sysctls }
        node["hostname"] = service.hostname
        if !service.extraHosts.isEmpty { node["extra_hosts"] = service.extraHosts }
        return node
    }

    private static func node(for network: ComposeNetwork) -> [String: Any] {
        var node: [String: Any] = [:]
        node["name"] = network.name
        if network.external { node["external"] = true }
        if network.isInternal { node["internal"] = true }
        if let subnet = network.subnet { node["ipam"] = ["config": [["subnet": subnet]]] }
        if !network.labels.isEmpty { node["labels"] = network.labels }
        return node
    }

    private static func node(for volume: ComposeVolume) -> [String: Any] {
        var node: [String: Any] = [:]
        node["name"] = volume.name
        if volume.external { node["external"] = true }
        if !volume.labels.isEmpty { node["labels"] = volume.labels }
        return node
    }

    /// Seconds as compose writes a duration: `90` is `1m30s`, `0.5` is `500ms`.
    static func duration(_ seconds: Double) -> String {
        guard seconds == seconds.rounded() else { return "\(Int((seconds * 1000).rounded()))ms" }
        var remaining = Int(seconds)
        guard remaining > 0 else { return "0s" }
        var text = ""
        for (unit, size) in [("h", 3600), ("m", 60), ("s", 1)] where remaining >= size {
            text += "\(remaining / size)\(unit)"
            remaining %= size
        }
        return text
    }
}
