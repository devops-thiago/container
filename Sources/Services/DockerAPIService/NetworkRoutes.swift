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
import Foundation
import NIOHTTP1

/// The engine's networks as the network routes see them. The agent answers it from the API
/// server; tests answer it from a fake.
public protocol EngineNetworks: Sendable {
    func list() async throws -> [NetworkResource]
    /// Makes a network with the engine's default network plugin. A name in use is a 409.
    func create(_ plan: DockerNetworkPlan) async throws -> NetworkResource
    /// Deletes a network. With `requiredLabels`, the engine deletes it only if it carries them.
    func delete(_ name: String, requiredLabels: [String: String]?) async throws
}

/// A Docker network create, mapped onto the engine.
public struct DockerNetworkPlan: Sendable, Equatable {
    public var name: String
    public var mode: NetworkMode
    public var ipv4Subnet: CIDRv4?
    public var ipv6Subnet: CIDRv6?
    public var labels: [String: String]
}

/// `POST /networks/create`'s body.
public struct DockerNetworkCreateBody: Decodable, Sendable {
    public struct IPAMBody: Decodable, Sendable {
        public var Driver: String?
        public var Config: [IPAMConfigBody]?
        public var Options: [String: String]?
    }

    public struct IPAMConfigBody: Decodable, Sendable {
        public var Subnet: String?
        public var IPRange: String?
        public var Gateway: String?
        public var AuxiliaryAddresses: [String: String]?
    }

    public var Name: String?
    public var Driver: String?
    public var Scope: String?
    public var Internal: Bool?
    public var Attachable: Bool?
    public var Ingress: Bool?
    public var ConfigOnly: Bool?
    public var ConfigFrom: DockerIgnoredValue?
    public var IPAM: IPAMBody?
    public var EnableIPv4: Bool?
    public var EnableIPv6: Bool?
    public var Options: [String: String]?
    public var Labels: [String: String]?
}

/// `POST /networks/{id}/connect`'s and `disconnect`'s body.
public struct DockerNetworkConnectBody: Decodable, Sendable {
    public struct EndpointBody: Decodable, Sendable {
        public var Aliases: [String]?
        public var IPAMConfig: DockerIgnoredValue?
        public var Links: [String]?
    }

    public var Container: String?
    public var EndpointConfig: EndpointBody?
    public var Force: Bool?
}

/// A network as `GET /networks` and `GET /networks/{id}` show it.
public struct DockerNetwork: Encodable, Sendable, Equatable {
    public struct IPAMBody: Encodable, Sendable, Equatable {
        public var Driver: String
        public var Options: [String: String]
        public var Config: [IPAMConfigBody]
    }

    public struct IPAMConfigBody: Encodable, Sendable, Equatable {
        public var Subnet: String
        public var Gateway: String?
    }

    public struct ConfigFromBody: Encodable, Sendable, Equatable {
        public var Network: String
    }

    public struct EndpointBody: Encodable, Sendable, Equatable {
        public var Name: String
        public var EndpointID: String
        public var MacAddress: String
        public var IPv4Address: String
        public var IPv6Address: String
    }

    public var Name: String
    public var Id: String
    public var Created: String
    public var Scope: String
    public var Driver: String
    public var EnableIPv4: Bool
    public var EnableIPv6: Bool
    public var IPAM: IPAMBody
    public var Internal: Bool
    public var Attachable: Bool
    public var Ingress: Bool
    public var ConfigFrom: ConfigFromBody
    public var ConfigOnly: Bool
    public var Containers: [String: EndpointBody]
    public var Options: [String: String]
    public var Labels: [String: String]
}

public struct DockerNetworkCreateResponse: Encodable, Sendable, Equatable {
    public var Id: String
    public var Warning: String
}

public struct DockerNetworkPruneReport: Encodable, Sendable, Equatable {
    public var NetworksDeleted: [String]?
}

/// The engine's networks in Docker's shapes, and the choices the network routes make.
///
/// A network's ID is its engine name, as a container's `NetworkSettings` already reports it.
/// The engine's default network is Docker's `bridge`; both drivers Docker sees are `bridge`,
/// a host-only network being an `Internal` one.
public enum NetworkMapper {
    /// Names Docker keeps for its own networks.
    public static let predefined: Set<String> = ["bridge", "host", "none"]

    public static func name(_ network: NetworkResource) -> String {
        network.isBuiltin ? "bridge" : network.name
    }

    public static func network(_ network: NetworkResource, containers: [DockerContainer]?) -> DockerNetwork {
        let configuration = network.configuration
        var config = [DockerNetwork.IPAMConfigBody(Subnet: network.status.ipv4Subnet.description, Gateway: network.status.ipv4Gateway.description)]
        if let v6 = network.status.ipv6Subnet {
            config.append(.init(Subnet: v6.description, Gateway: nil))
        }
        var labels = configuration.labels.dictionary
        labels[ResourceLabelKeys.role] = nil
        return DockerNetwork(
            Name: name(network),
            Id: network.id,
            Created: ContainerViewMapper.timestamp(configuration.creationDate),
            Scope: "local",
            Driver: "bridge",
            EnableIPv4: true,
            EnableIPv6: network.status.ipv6Subnet != nil,
            IPAM: .init(Driver: "default", Options: [:], Config: config),
            Internal: configuration.mode == .hostOnly,
            Attachable: false,
            Ingress: false,
            ConfigFrom: .init(Network: ""),
            ConfigOnly: false,
            Containers: containers.map { endpoints(network, $0) } ?? [:],
            Options: configuration.options,
            Labels: labels)
    }

    /// The running containers attached to `network`, by Docker ID.
    static func endpoints(_ network: NetworkResource, _ containers: [DockerContainer]) -> [String: DockerNetwork.EndpointBody] {
        var endpoints: [String: DockerNetwork.EndpointBody] = [:]
        for container in containers where ContainerViewMapper.isRunning(container.snapshot) {
            guard let attachment = container.snapshot.networks.first(where: { $0.network == network.id }) else { continue }
            endpoints[container.dockerID] = .init(
                Name: container.name, EndpointID: "", MacAddress: attachment.macAddress?.description ?? "",
                IPv4Address: attachment.ipv4Address.description, IPv6Address: attachment.ipv6Address?.description ?? "")
        }
        return endpoints
    }

    /// The containers configured on each network, running or not, by engine network name.
    public static func users(_ containers: [DockerContainer]) -> [String: [DockerContainer]] {
        var users: [String: [DockerContainer]] = [:]
        for container in containers {
            for network in Set(container.snapshot.configuration.networks.map(\.network)) {
                users[network, default: []].append(container)
            }
        }
        return users
    }

    /// The network `term` names, as dockerd finds one: a full ID, then an exact name, then a
    /// unique ID prefix.
    public static func resolve(_ term: String, in networks: [NetworkResource]) throws(DockerAPIError) -> NetworkResource {
        if let exact = networks.first(where: { $0.id == term }) { return exact }
        let byName = networks.filter { name($0) == term }
        if byName.count == 1 { return byName[0] }
        let byPrefix = networks.filter { $0.id.hasPrefix(term) }
        if byPrefix.count == 1 { return byPrefix[0] }
        if byPrefix.count > 1 {
            throw .badRequest("network \(term) is ambiguous (\(byPrefix.count) matches found based on ID prefix)")
        }
        throw .notFound("network \(term) not found")
    }

    static let listAccepted: Set<String> = ["dangling", "driver", "id", "label", "name", "scope", "type"]

    /// The `filters` of `GET /networks`.
    public static func list(
        _ networks: [NetworkResource], filters: [String: [String]], users: [String: [DockerContainer]]
    ) throws(DockerAPIError) -> [NetworkResource] {
        try DockerFilters.validate(filters, accepted: listAccepted)
        let dangling = try danglingFilter(filters)
        for value in filters["type"] ?? [] where !["builtin", "custom"].contains(value) {
            throw .badRequest("invalid value for filter 'type': must be 'builtin' or 'custom'")
        }
        return networks.filter { network in
            let shown = Self.network(network, containers: nil)
            let attached = (users[network.id] ?? []).contains { ContainerViewMapper.isRunning($0.snapshot) }
            return DockerFilters.exactMatch(filters["driver"], shown.Driver) && DockerFilters.patternMatch(filters["name"], shown.Name)
                && DockerFilters.patternMatch(filters["id"], network.id) && DockerFilters.labelsMatch(filters["label"], shown.Labels)
                && DockerFilters.exactMatch(filters["scope"], shown.Scope)
                && dangling.map { $0 ? !network.isBuiltin && !attached : network.isBuiltin || attached } ?? true
                && (filters["type"]?.first.map { $0 == "builtin" ? network.isBuiltin : !network.isBuiltin } ?? true)
        }.sorted { name($0) < name($1) }
    }

    static func danglingFilter(_ filters: [String: [String]]) throws(DockerAPIError) -> Bool? {
        guard let values = filters["dangling"] else { return nil }
        guard values.count == 1 else { throw .badRequest(#"got more than one value for filter key "dangling""#) }
        switch values[0] {
        case "1", "true": return true
        case "0", "false": return false
        default: throw .badRequest(#"invalid value for filter 'dangling': must be "true" (or "1"), or "false" (or "0")"#)
        }
    }

    static let pruneAccepted: Set<String> = ["label", "label!"]

    /// The networks `POST /networks/prune` removes: not the default one, not one any container
    /// is configured on (running or not, which is more careful than dockerd's running-only
    /// check), and matching the label filters.
    public static func pruneSelection(
        _ networks: [NetworkResource], filters: [String: [String]], users: [String: [DockerContainer]]
    ) throws(DockerAPIError) -> [NetworkResource] {
        try DockerFilters.validate(filters, accepted: pruneAccepted, unsupported: ["until"])
        return networks.filter { network in
            !network.isBuiltin && (users[network.id] ?? []).isEmpty && DockerFilters.pruneLabelsMatch(filters, network.configuration.labels.dictionary)
        }.sorted { $0.id < $1.id }
    }

    /// A create, refused as dockerd refuses what the engine cannot be: a driver other than
    /// `bridge`, an address range or auxiliary address, a gateway other than the subnet's first
    /// address, or IPv4 turned off. Options the engine has no place for are reported back in
    /// `Warning`.
    public static func plan(_ body: DockerNetworkCreateBody) throws(DockerAPIError) -> (DockerNetworkPlan, warnings: [String]) {
        let name = body.Name ?? ""
        guard !name.isEmpty else { throw .badRequest("network name must not be empty") }
        if predefined.contains(name) || name == "default" {
            throw DockerAPIError(.forbidden, "operation is not permitted on predefined \(name) network ")
        }
        guard NetworkResource.nameValid(name) else {
            throw .badRequest(
                "invalid network name \"\(name)\": SiliconShip's networks take lowercase letters, digits, '.', '_' and '-', up to 63 characters")
        }
        switch body.Driver ?? "" {
        case "", "bridge":
            break
        case "host", "none":
            throw DockerAPIError(.forbidden, "only one instance of \"\(body.Driver ?? "")\" network is allowed")
        case let driver:
            throw .badRequest("network driver \"\(driver)\" is not supported by SiliconShip: use bridge")
        }
        if body.EnableIPv4 == false {
            throw .badRequest("disabling IPv4 is not supported by SiliconShip")
        }
        for (flag, label) in [(body.Attachable, "attachable"), (body.Ingress, "ingress"), (body.ConfigOnly, "config-only")] where flag == true {
            throw .badRequest("\(label) networks are not supported by SiliconShip")
        }
        if let scope = body.Scope, !scope.isEmpty, scope != "local" {
            throw .badRequest("network scope \"\(scope)\" is not supported by SiliconShip: networks are local")
        }
        if let driver = body.IPAM?.Driver, !driver.isEmpty, driver != "default" {
            throw .badRequest("IPAM driver \"\(driver)\" is not supported by SiliconShip")
        }
        var ipv4: CIDRv4?
        var ipv6: CIDRv6?
        for config in body.IPAM?.Config ?? [] {
            guard let text = config.Subnet, !text.isEmpty else {
                throw .badRequest("an IPAM config without a subnet is not supported by SiliconShip")
            }
            if config.IPRange.map({ !$0.isEmpty }) ?? false {
                throw .badRequest("an IP range is not supported by SiliconShip: the whole subnet is used")
            }
            if !(config.AuxiliaryAddresses ?? [:]).isEmpty {
                throw .badRequest("auxiliary addresses are not supported by SiliconShip")
            }
            if text.contains(":") {
                guard body.EnableIPv6 == true else { continue }
                guard ipv6 == nil, let subnet = try? CIDRv6(text) else {
                    throw .badRequest(ipv6 == nil ? "invalid subnet \(text)" : "more than one IPv6 subnet is not supported by SiliconShip")
                }
                ipv6 = subnet
                continue
            }
            guard ipv4 == nil else { throw .badRequest("more than one IPv4 subnet is not supported by SiliconShip") }
            guard let subnet = try? CIDRv4(text) else { throw .badRequest("invalid subnet \(text)") }
            guard subnet.address == subnet.lower else {
                throw .badRequest("invalid network config:\ninvalid subnet \(text): it should be \(subnet.lower)/\(subnet.prefix)")
            }
            if let gateway = config.Gateway, !gateway.isEmpty, gateway != subnet.gateway.description {
                throw .badRequest("gateway \(gateway) is not supported by SiliconShip: a network's gateway is its subnet's first address, \(subnet.gateway)")
            }
            ipv4 = subnet
        }
        var labels = body.Labels ?? [:]
        guard labels[ResourceLabelKeys.role] == nil, labels[ResourceLabelKeys.plugin] == nil else {
            throw .badRequest("the labels \(ResourceLabelKeys.role) and \(ResourceLabelKeys.plugin) are reserved")
        }
        do {
            labels = try ResourceLabels(labels).dictionary
        } catch {
            throw .badRequest("invalid label: \(error)")
        }
        var warnings: [String] = []
        let options = (body.Options ?? [:]).keys.sorted()
        if !options.isEmpty {
            warnings.append("network options are not supported by SiliconShip and were ignored: \(options.joined(separator: ", "))")
        }
        if !(body.IPAM?.Options ?? [:]).isEmpty {
            warnings.append("IPAM options are not supported by SiliconShip and were ignored")
        }
        return (
            DockerNetworkPlan(name: name, mode: body.Internal == true ? .hostOnly : .nat, ipv4Subnet: ipv4, ipv6Subnet: ipv6, labels: labels),
            warnings
        )
    }

    /// The container's networks with `network` added: its name is an alias on it, as on a
    /// Docker user-defined network, with the client's aliases.
    static func connecting(_ container: DockerContainer, to network: NetworkResource, aliases: [String]) -> [AttachmentConfiguration] {
        var names = aliases
        let nameIsAlias = container.name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            $0.wholeMatch(of: #/[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?/#) != nil
        }
        if !network.isBuiltin && nameIsAlias { names.append(container.name) }
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        return container.snapshot.configuration.networks + [
            AttachmentConfiguration(network: network.id, options: AttachmentOptions(hostname: container.engineID, mtu: 1280, aliases: names))
        ]
    }
}

/// `GET /networks`, `GET /networks/{id}`, `POST /networks/create`, `DELETE /networks/{id}`,
/// `POST /networks/prune`, and `connect` and `disconnect` for a container that has not run.
public enum NetworkRoutes {
    /// - Parameter events: where creates, removals, connects and disconnects are reported; nil
    ///   reports nothing.
    public static func register(
        on router: inout DockerRouter, engine: some EngineNetworks, containers: some EngineContainers, identities: DockerIdentityStore,
        events: DockerEventBus? = nil
    ) {
        let routes = Routes(engine: engine, containers: containers, identities: identities, events: events)
        router.add(.GET, "/networks") { request, _ in try await routes.list(request) }
        router.add(.POST, "/networks/create") { request, _ in try await routes.create(request) }
        router.add(.POST, "/networks/prune") { request, _ in try await routes.prune(request) }
        router.add(.GET, "/networks/{id}") { _, parameters in try await routes.inspect(try parameters["id"]) }
        router.add(.DELETE, "/networks/{id}") { _, parameters in try await routes.delete(try parameters["id"]) }
        router.add(.POST, "/networks/{id}/connect") { request, parameters in try await routes.connect(try parameters["id"], request, connect: true) }
        router.add(.POST, "/networks/{id}/disconnect") { request, parameters in
            try await routes.connect(try parameters["id"], request, connect: false)
        }
    }

    struct Routes<Engine: EngineNetworks, Containers: EngineContainers>: Sendable {
        let engine: Engine
        let containers: Containers
        let identities: DockerIdentityStore
        let events: DockerEventBus?

        /// A network event as dockerd reports one: by ID, with its name and driver.
        func report(_ action: String, _ network: NetworkResource, extra: [String: String] = [:]) async {
            guard let events else { return }
            let shown = NetworkMapper.network(network, containers: nil)
            var attributes = ["name": shown.Name, "type": shown.Driver]
            attributes.merge(extra) { _, new in new }
            await events.publish(type: "network", action: action, actorID: shown.Id, attributes: attributes)
        }

        func dockerContainers() async throws -> [DockerContainer] {
            await identities.join(try await containers.list())
        }

        func list(_ request: DockerRequest) async throws -> DockerResponse {
            let users = NetworkMapper.users(try await dockerContainers())
            let networks = try NetworkMapper.list(try await engine.list(), filters: try request.filters(), users: users)
            return try .json(networks.map { NetworkMapper.network($0, containers: nil) })
        }

        func inspect(_ term: String) async throws -> DockerResponse {
            let network = try NetworkMapper.resolve(term, in: try await engine.list())
            return try .json(NetworkMapper.network(network, containers: try await dockerContainers()))
        }

        func create(_ request: DockerRequest) async throws -> DockerResponse {
            let (plan, warnings) = try NetworkMapper.plan(try request.decode(DockerNetworkCreateBody.self))
            if try await engine.list().contains(where: { $0.name == plan.name }) {
                throw DockerAPIError.conflict("network with name \(plan.name) already exists")
            }
            let network = try await engine.create(plan)
            await report("create", network)
            return try .json(DockerNetworkCreateResponse(Id: network.id, Warning: warnings.joined(separator: "\n")), status: .created)
        }

        /// 403 for the default network and for one a running container is attached to, as
        /// dockerd refuses them. A stopped container configured on it does not hold it, as in
        /// dockerd; it fails to start until the network is back.
        func delete(_ term: String) async throws -> DockerResponse {
            let network = try NetworkMapper.resolve(term, in: try await engine.list())
            if network.isBuiltin {
                throw DockerAPIError(.forbidden, "bridge is a pre-defined network and cannot be removed")
            }
            let attached = (NetworkMapper.users(try await dockerContainers())[network.id] ?? []).filter { ContainerViewMapper.isRunning($0.snapshot) }
            if !attached.isEmpty {
                throw DockerAPIError(
                    .forbidden,
                    "error while removing network: network \(network.name) id \(network.id) has active endpoints (\(attached.map(\.name).joined(separator: ", ")))"
                )
            }
            try await engine.delete(network.id, requiredLabels: nil)
            await report("destroy", network)
            return .empty()
        }

        /// Removes what `NetworkMapper.pruneSelection` picks, skipping one it cannot remove. The
        /// `key=value` label filters are also handed to the engine, which refuses a network that
        /// does not carry them.
        func prune(_ request: DockerRequest) async throws -> DockerResponse {
            let filters = try request.filters()
            let users = NetworkMapper.users(try await dockerContainers())
            let selected = try NetworkMapper.pruneSelection(try await engine.list(), filters: filters, users: users)
            let required = VolumeMapper.requiredLabels(filters)
            var deleted: [String] = []
            for network in selected {
                do {
                    try await engine.delete(network.id, requiredLabels: required)
                    deleted.append(network.name)
                    await report("destroy", network)
                } catch {
                    continue
                }
            }
            return try .json(DockerNetworkPruneReport(NetworksDeleted: deleted.isEmpty ? nil : deleted))
        }

        /// Connects or disconnects a container that has been created and has not run: the engine
        /// fixes a container's networks when it is created, so the container is deleted and made
        /// again under the same ID with its networks changed, and put back as it was if that
        /// fails. A container that has run is a 409.
        func connect(_ term: String, _ request: DockerRequest, connect: Bool) async throws -> DockerResponse {
            let body = try request.decode(DockerNetworkConnectBody.self)
            let network = try NetworkMapper.resolve(term, in: try await engine.list())
            guard let reference = body.Container, !reference.isEmpty else {
                throw DockerAPIError.badRequest("no container was given to \(connect ? "connect" : "disconnect")")
            }
            let container = try DockerIdentityTable.resolve(reference, in: try await dockerContainers())
            let status = ContainerViewMapper.status(container.snapshot)
            guard status == .created else {
                throw DockerAPIError.conflict(
                    "container \(container.name) is \(status.rawValue): SiliconShip can \(connect ? "connect" : "disconnect") a container "
                        + "\(connect ? "to" : "from") a network only before it first starts, because its virtual machine's networks are fixed then. "
                        + "Create the container with --network instead.")
            }
            let configured = container.snapshot.configuration.networks
            let attached = configured.contains { $0.network == network.id }
            var networks: [AttachmentConfiguration]
            if connect {
                guard !attached else {
                    throw DockerAPIError(.forbidden, "endpoint with name \(container.name) already exists in network \(NetworkMapper.name(network))")
                }
                if body.EndpointConfig?.IPAMConfig != nil {
                    throw DockerAPIError.badRequest("a static address is not supported by SiliconShip: the network assigns one")
                }
                networks = NetworkMapper.connecting(container, to: network, aliases: body.EndpointConfig?.Aliases ?? [])
            } else {
                guard attached else {
                    throw DockerAPIError(.forbidden, "container \(container.dockerID) is not connected to network \(NetworkMapper.name(network))")
                }
                networks = configured.filter { $0.network != network.id }
                guard !networks.isEmpty else {
                    throw DockerAPIError.conflict(
                        "container \(container.name) would have no network left: SiliconShip keeps every container on at least one network")
                }
            }
            try await recreate(container, networks: networks, requester: request.peer?.requester)
            await report(connect ? "connect" : "disconnect", network, extra: ["container": container.dockerID])
            return .empty(.ok)
        }

        /// `requester` is who the engine's folder panel names, should the new container's bind
        /// mounts need asking for again.
        func recreate(_ container: DockerContainer, networks: [AttachmentConfiguration], requester: String?) async throws {
            let original = container.snapshot.configuration
            var changed = original
            changed.networks = networks
            let extras = container.extras ?? DockerContainerExtras(image: ContainerViewMapper.image(container), imageID: ContainerViewMapper.imageID(container))
            func plan(_ configuration: ContainerConfiguration) -> DockerCreatePlan {
                DockerCreatePlan(configuration: configuration, autoRemove: extras.autoRemove, volumes: [], extras: extras, warnings: [])
            }
            // The same container to a client: the engine's destroy and create are not said.
            await events?.recreating(container)
            do {
                try await containers.delete(container.snapshot, force: false)
            } catch {
                await events?.recreateEnded(container.engineID)
                throw error
            }
            let incarnation: String
            do {
                incarnation = try await containers.create(plan(changed), requester: requester)
            } catch {
                if let restored = try? await containers.create(plan(original), requester: requester) {
                    await identities.recreated(container, incarnation: restored)
                } else {
                    await events?.recreateEnded(container.engineID)
                }
                throw error
            }
            await identities.recreated(container, incarnation: incarnation)
        }
    }
}
