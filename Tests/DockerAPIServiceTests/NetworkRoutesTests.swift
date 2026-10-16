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
import NIOCore
import NIOHTTP1
import Testing

@testable import DockerAPIService

/// The network mapper, the create mapping, filters and prune selection, and the routes over
/// fakes, connect and disconnect included.
@Suite(.timeLimit(.minutes(1)))
struct NetworkRoutesTests {
    let networks: FakeNetworks
    let engine: FakeEngine
    let identities = DockerIdentityStore(persistence: nil)
    let router: DockerRouter
    let containerRouter: DockerRouter

    static let mine = FakeNetworks.network("m229-net", subnet: "10.229.0.0/24", labels: ["m229": "1"])
    static let internalNetwork = FakeNetworks.network("backend", subnet: "10.5.0.0/24", mode: .hostOnly, labels: ["tier": "db"])

    /// A container configured on `networks`, attached to them while running.
    static func on(_ name: String, _ networks: [String], running: Bool = false) throws -> ContainerSnapshot {
        var configuration = Fixtures.configuration(id: name)
        configuration.networks = networks.map { AttachmentConfiguration(network: $0, options: AttachmentOptions(hostname: name)) }
        let attachments = running ? try networks.map { try Fixtures.attachment($0, address: "10.229.0.7/24") } : []
        return Fixtures.snapshot(configuration, status: running ? .running : .stopped, started: running ? Fixtures.now : nil, networks: attachments)
    }

    init(_ networks: [NetworkResource] = [mine, internalNetwork], containers: [ContainerSnapshot] = []) {
        self.networks = FakeNetworks(networks)
        engine = FakeEngine(snapshots: containers)
        var router = DockerRouter()
        NetworkRoutes.register(on: &router, engine: self.networks, containers: engine, identities: identities)
        self.router = router
        var containerRouter = DockerRouter()
        ContainerRoutes.register(on: &containerRouter, engine: engine, identities: identities, streams: DockerContainerStreams(engine: engine), now: { Fixtures.now })
        self.containerRouter = containerRouter
    }

    func call(
        _ method: HTTPMethod, _ uri: String, body: String = "", on router: DockerRouter? = nil, peer: DockerPeer? = nil
    ) async throws -> ContainerRoutesTests.Answer {
        let request = try DockerRequest(method: method, uri: "/v1.48" + uri, headers: [:], body: ByteBuffer(string: body), peer: peer)
        guard case .data(let status, _, let buffer, _) = await (router ?? self.router).respond(to: request) else {
            Issue.record("expected a whole response")
            return .init(status: .internalServerError, body: "")
        }
        return .init(status: status, body: String(buffer: buffer))
    }

    @Test("the default network is bridge; a host-only one is internal; both are Docker's bridge driver")
    func mapper() throws {
        let running = DockerIdentityTable().joined([try Self.on("c1", [Fixtures.builtin], running: true), try Self.on("c2", [Fixtures.builtin])])
        let bridge = NetworkMapper.network(FakeNetworks.builtin, containers: running)
        #expect(bridge.Name == "bridge" && bridge.Id == Fixtures.builtin && bridge.Driver == "bridge" && !bridge.Internal)
        #expect(bridge.Labels.isEmpty)
        #expect(bridge.IPAM.Config == [.init(Subnet: "192.168.64.0/24", Gateway: "192.168.64.1")])
        // Only a running container has an endpoint.
        #expect(bridge.Containers.keys.sorted() == [DockerIdentityTable.foreignID(engineID: "c1")])
        #expect(bridge.Containers.values.first?.IPv4Address == "10.229.0.7/24")
        let backend = NetworkMapper.network(Self.internalNetwork, containers: nil)
        #expect(backend.Name == "backend" && backend.Internal && backend.Driver == "bridge")
        #expect(backend.Containers.isEmpty)
        #expect(backend.Labels == ["tier": "db"])
    }

    @Test("a network resolves by ID, then Docker name, then a unique ID prefix")
    func resolve() throws {
        let all = [FakeNetworks.builtin, Self.mine, Self.internalNetwork, FakeNetworks.network("m229-net2")]
        #expect(try NetworkMapper.resolve("bridge", in: all).id == Fixtures.builtin)
        #expect(try NetworkMapper.resolve(Fixtures.builtin, in: all).id == Fixtures.builtin)
        #expect(try NetworkMapper.resolve("m229-net", in: all).id == "m229-net")
        #expect(try NetworkMapper.resolve("back", in: all).id == "backend")
        #expect(throws: DockerAPIError.badRequest("network m229 is ambiguous (2 matches found based on ID prefix)")) { try NetworkMapper.resolve("m229", in: all) }
        #expect(throws: DockerAPIError.notFound("network nope not found")) { try NetworkMapper.resolve("nope", in: all) }
    }

    func plan(_ json: String) throws -> (DockerNetworkPlan, warnings: [String]) {
        try NetworkMapper.plan(try JSONDecoder().decode(DockerNetworkCreateBody.self, from: Data(json.utf8)))
    }

    @Test("bridge is nat, internal is host-only, a subnet is the engine's subnet; what the engine cannot be is refused")
    func createMapping() throws {
        let nat = try plan(#"{"Name":"m229-a","Driver":"bridge","Labels":{"m229":"1"},"IPAM":{"Driver":"default","Config":[{"Subnet":"10.9.8.0/24","Gateway":"10.9.8.1"}]}}"#)
        let subnet = try CIDRv4("10.9.8.0/24")
        #expect(nat.0 == DockerNetworkPlan(name: "m229-a", mode: .nat, ipv4Subnet: subnet, ipv6Subnet: nil, labels: ["m229": "1"]))
        #expect(nat.warnings.isEmpty)
        let hostOnly = try plan(#"{"Name":"m229-b","Internal":true}"#)
        #expect(hostOnly.0.mode == .hostOnly && hostOnly.0.ipv4Subnet == nil)
        let v6 = try plan(#"{"Name":"m229-c","EnableIPv6":true,"IPAM":{"Config":[{"Subnet":"fd00:1::/64"},{"Subnet":"10.1.2.0/24"}]}}"#)
        let expected6 = try CIDRv6("fd00:1::/64")
        let expected4 = try CIDRv4("10.1.2.0/24")
        #expect(v6.0.ipv6Subnet == expected6 && v6.0.ipv4Subnet == expected4)
        // An IPv6 subnet without EnableIPv6 is ignored, as dockerd ignores it.
        #expect(try plan(#"{"Name":"m229-d","IPAM":{"Config":[{"Subnet":"fd00:1::/64"}]}}"#).0.ipv6Subnet == nil)
        let options = try plan(#"{"Name":"m229-e","Options":{"com.docker.network.bridge.name":"br9"}}"#)
        #expect(options.warnings.count == 1)

        func refusal(_ json: String) -> DockerAPIError? {
            do {
                _ = try plan(json)
                return nil
            } catch let error as DockerAPIError {
                return error
            } catch {
                return .internalError("\(error)")
            }
        }
        #expect(refusal(#"{"Name":"bridge"}"#) == DockerAPIError(.forbidden, "operation is not permitted on predefined bridge network "))
        #expect(refusal(#"{"Name":"default"}"#)?.status == .forbidden)
        #expect(refusal(#"{"Name":"x","Driver":"host"}"#) == DockerAPIError(.forbidden, #"only one instance of "host" network is allowed"#))
        #expect(refusal(#"{"Name":"x","Driver":"none"}"#)?.status == .forbidden)
        #expect(refusal(#"{"Name":"x","Driver":"overlay"}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","Driver":"macvlan"}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"Upper"}"#)?.status == .badRequest)
        #expect(refusal(#"{}"#) == .badRequest("network name must not be empty"))
        #expect(
            refusal(#"{"Name":"x","IPAM":{"Config":[{"Subnet":"10.9.8.1/24"}]}}"#) == .badRequest("invalid network config:\ninvalid subnet 10.9.8.1/24: it should be 10.9.8.0/24"))
        #expect(refusal(#"{"Name":"x","IPAM":{"Config":[{"Subnet":"10.9.8.0/24","Gateway":"10.9.8.254"}]}}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","IPAM":{"Config":[{"Subnet":"10.9.8.0/24","IPRange":"10.9.8.0/25"}]}}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","IPAM":{"Config":[{"Subnet":"10.9.8.0/24"},{"Subnet":"10.9.9.0/24"}]}}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","EnableIPv4":false}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","Attachable":true}"#)?.status == .badRequest)
        #expect(refusal(#"{"Name":"x","Labels":{"com.apple.container.resource.role":"builtin"}}"#)?.status == .badRequest)
    }

    @Test("the list filters, and the prune selection that keeps the default network and any network a container is on")
    func filtersAndPrune() throws {
        let all = [FakeNetworks.builtin, Self.mine, Self.internalNetwork, FakeNetworks.network("m229-idle", labels: ["m229": "1"])]
        let users = NetworkMapper.users(DockerIdentityTable().joined([try Self.on("c1", ["backend"], running: true), try Self.on("c2", ["m229-net"])]))
        func names(_ filters: [String: [String]]) throws -> [String] {
            try NetworkMapper.list(all, filters: filters, users: users).map(NetworkMapper.name)
        }
        #expect(try names([:]) == ["backend", "bridge", "m229-idle", "m229-net"])
        #expect(try names(["name": ["m229"]]) == ["m229-idle", "m229-net"])
        #expect(try names(["id": [Fixtures.builtin]]) == ["bridge"])
        #expect(try names(["label": ["m229=1"]]) == ["m229-idle", "m229-net"])
        #expect(try names(["driver": ["bridge"]]).count == 4)
        #expect(try names(["type": ["builtin"]]) == ["bridge"])
        #expect(try names(["type": ["custom"]]) == ["backend", "m229-idle", "m229-net"])
        // Dangling is about attachments, as dockerd counts them: a stopped container has none.
        #expect(try names(["dangling": ["true"]]) == ["m229-idle", "m229-net"])
        #expect(try names(["dangling": ["false"]]) == ["backend", "bridge"])
        #expect(throws: DockerAPIError.badRequest("invalid value for filter 'type': must be 'builtin' or 'custom'")) { try names(["type": ["x"]]) }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'subnet'")) { try names(["subnet": ["x"]]) }

        func pruned(_ filters: [String: [String]]) throws -> [String] {
            try NetworkMapper.pruneSelection(all, filters: filters, users: users).map(\.id)
        }
        // The stopped container's network is kept: it would not start without it.
        #expect(try pruned([:]) == ["m229-idle"])
        #expect(try pruned(["label": ["m229=1"]]) == ["m229-idle"])
        #expect(try pruned(["label!": ["m229"]]) == [])
        #expect(throws: DockerAPIError.badRequest("the 'until' filter is not supported")) { try pruned(["until": ["24h"]]) }
    }

    @Test("create, inspect, delete and prune over the routes, with dockerd's 403 and 409")
    func routes() async throws {
        let routes = NetworkRoutesTests(containers: [try Self.on("c1", ["backend"], running: true), try Self.on("c2", [Fixtures.builtin])])
        let created = try await routes.call(.POST, "/networks/create", body: #"{"Name":"m229-new","Labels":{"m229":"1"},"IPAM":{"Config":[{"Subnet":"10.7.0.0/24"}]}}"#)
        #expect(created.status == .created)
        #expect(try created.json() as? [String: String] == ["Id": "m229-new", "Warning": ""])
        #expect(routes.networks.calls == ["create m229-new nat 10.7.0.0/24"])
        let duplicate = try await routes.call(.POST, "/networks/create", body: #"{"Name":"m229-new"}"#)
        #expect(duplicate.status == .conflict && duplicate.message == "network with name m229-new already exists")

        let inspect = try #require(try await routes.call(.GET, "/networks/backend").json() as? [String: Any])
        #expect((inspect["Containers"] as? [String: Any])?.keys.sorted() == [DockerIdentityTable.foreignID(engineID: "c1")])
        #expect(try await routes.call(.GET, "/networks/nope").message == "network nope not found")

        let builtin = try await routes.call(.DELETE, "/networks/bridge")
        #expect(builtin.status == .forbidden && builtin.message == "bridge is a pre-defined network and cannot be removed")
        let active = try await routes.call(.DELETE, "/networks/backend")
        #expect(active.status == .forbidden)
        #expect(active.message == "error while removing network: network backend id backend has active endpoints (c1)")
        #expect(try await routes.call(.DELETE, "/networks/m229-new").status == .noContent)
        #expect(routes.networks.names == [Fixtures.builtin, "backend", "m229-net"].sorted())

        let report = try #require(try await routes.call(.POST, "/networks/prune?filters=%7B%22label%22%3A%5B%22m229%3D1%22%5D%7D").json() as? [String: Any])
        #expect(report["NetworksDeleted"] as? [String] == ["m229-net"])
        let empty = try #require(try await routes.call(.POST, "/networks/prune?filters=%7B%22label%22%3A%5B%22m229%3D1%22%5D%7D").json() as? [String: Any])
        #expect(empty["NetworksDeleted"] == nil)
        #expect(routes.networks.names == [Fixtures.builtin, "backend"].sorted())
    }

    /// `docker network connect` without `--ip`, as docker/cli v29.8 marshals it: the CLI always
    /// sets `IPAMConfig`, and its zero-valued addresses are omitted.
    static let cliConnectBody = #"""
        {"Container":"m-net-c","EndpointConfig":{"IPAMConfig":{},"Links":null,"Aliases":null,"DriverOpts":{},"GwPriority":0,"NetworkID":"","EndpointID":"","Gateway":"","IPAddress":"","MacAddress":"","IPPrefixLen":0,"IPv6Gateway":"","GlobalIPv6Address":"","GlobalIPv6PrefixLen":0,"DNSNames":null}}
        """#

    @Test("connect takes an IPAMConfig that names no address, as the Docker CLI sends; one with an address is a 400")
    func connectEmptyIPAMConfig() async throws {
        let routes = NetworkRoutesTests()
        let addresses = [#"{"IPv4Address":"10.7.0.9"}"#, #"{"IPv6Address":"fd00::9"}"#, #"{"LinkLocalIPs":["169.254.0.9"]}"#]
        _ = try await routes.call(.POST, "/containers/create?name=m-net-c", body: #"{"Image":"alpine","Cmd":["sleep","60"]}"#, on: routes.containerRouter)
        // Control: an address is refused, and nothing is remade.
        for ipam in addresses {
            let refused = try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"m-net-c","EndpointConfig":{"IPAMConfig":\#(ipam)}}"#)
            #expect(refused.status == .badRequest)
            #expect(refused.message == "a static address is not supported by SiliconShip: the network assigns one")
        }
        #expect(routes.engine.plans.count == 1)

        #expect(try await routes.call(.POST, "/networks/m229-net/connect", body: Self.cliConnectBody).status == .ok)
        let inspect = try #require(try await routes.call(.GET, "/containers/m-net-c/json", on: routes.containerRouter).json() as? [String: Any])
        let networks = try #require((inspect["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any])
        #expect(networks.keys.sorted() == ["bridge", "m229-net"])

        // Its fields sent empty, as another client may, is no request either.
        #expect(try await routes.call(.POST, "/networks/m229-net/disconnect", body: #"{"Container":"m-net-c"}"#).status == .ok)
        let emptied = #"{"Container":"m-net-c","EndpointConfig":{"IPAMConfig":{"IPv4Address":"","IPv6Address":"","LinkLocalIPs":[]}}}"#
        #expect(try await routes.call(.POST, "/networks/m229-net/connect", body: emptied).status == .ok)
    }

    @Test("connect and disconnect remake a created container under the same IDs; one that has run is a 409")
    func connect() async throws {
        let routes = NetworkRoutesTests()
        let created = try await routes.call(.POST, "/containers/create?name=m229-c", body: #"{"Image":"alpine","Cmd":["sleep","60"]}"#, on: routes.containerRouter)
        let id = try #require((try created.json() as? [String: Any])?["Id"] as? String)

        let connected = try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"m229-c","EndpointConfig":{"Aliases":["web"]}}"#)
        #expect(connected.status == .ok)
        let inspect = try #require(try await routes.call(.GET, "/containers/m229-c/json", on: routes.containerRouter).json() as? [String: Any])
        #expect(inspect["Id"] as? String == id)
        let networks = try #require((inspect["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any])
        #expect(networks.keys.sorted() == ["bridge", "m229-net"])
        #expect((networks["m229-net"] as? [String: Any])?["Aliases"] as? [String] == ["web", "m229-c"])
        #expect(routes.engine.calls.filter { $0.hasPrefix("delete") }.count == 1)
        #expect(routes.engine.plans.count == 2)

        let again = try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"m229-c"}"#)
        #expect(again.status == .forbidden)
        #expect(try await routes.call(.POST, "/networks/m229-net/disconnect", body: #"{"Container":"m229-c"}"#).status == .ok)
        let after = try #require(try await routes.call(.GET, "/containers/\(id)/json", on: routes.containerRouter).json() as? [String: Any])
        #expect(((after["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any])?.keys.sorted() == ["bridge"])
        #expect(try await routes.call(.POST, "/networks/bridge/disconnect", body: #"{"Container":"m229-c"}"#).status == .conflict)
        #expect(try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"nope"}"#).status == .notFound)

        // Control: once it has run, nothing is remade.
        let engineID = String(id.prefix(12))
        routes.engine.update(engineID) {
            $0.status = .running
            $0.startedDate = Fixtures.now
        }
        let refused = try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"m229-c"}"#)
        #expect(refused.status == .conflict)
        #expect(refused.message?.hasPrefix("container m229-c is running: SiliconShip can connect a container to a network only before it first starts") == true)
        #expect(routes.engine.plans.count == 3)
    }
}
