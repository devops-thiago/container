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
import DNSServer
import Synchronization
import Testing

@testable import ContainerAPIService
@testable import container_apiserver

/// One network helper's view: its attachments, which a test may change between queries the
/// way containers come and go while the engine runs.
private final class FakeNetwork: NetworkAttachmentTable {
    let id: String
    let subnet: CIDRv4
    private let current: Mutex<[ContainerResource.Attachment]>

    init(_ id: String, subnet: String, _ attachments: [ContainerResource.Attachment] = []) throws {
        self.id = id
        self.subnet = try CIDRv4(subnet)
        self.current = Mutex(attachments)
    }

    func attach(_ attachment: ContainerResource.Attachment) {
        current.withLock { $0.append(attachment) }
    }

    func lookup(hostname: String) async throws -> ContainerResource.Attachment? {
        current.withLock { $0.first { $0.hostname == hostname } }
    }

    func attachments() async throws -> [ContainerResource.Attachment] {
        current.withLock { $0.sorted { $0.hostname < $1.hostname } }
    }
}

/// The engine's directory with fake helpers behind it, answering through the same static
/// passes `NetworksService` runs.
private struct FakeDirectory: ContainerNetworkDirectory {
    let networks: [FakeNetwork]

    func network(containing address: IPv4Address) async -> String? {
        NetworksService.network(
            containing: address, among: Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0.subnet) }))
    }

    func lookup(name: String, network: String?) async throws -> ContainerResource.Attachment? {
        let scoped = networks.filter { network == nil || $0.id == network }.sorted { $0.id < $1.id }
        return try await NetworksService.lookup(name: name, on: scoped)
    }
}

private func attachment(
    _ hostname: String, on network: String, _ address: String, ipv6: String? = nil, aliases: [String] = []
) throws -> ContainerResource.Attachment {
    let cidr = try CIDRv4(address)
    return ContainerResource.Attachment(
        network: network,
        hostname: hostname,
        ipv4Address: cidr,
        ipv4Gateway: cidr.gateway,
        ipv6Address: try ipv6.map { try CIDRv6($0) },
        macAddress: nil,
        aliases: aliases
    )
}

private func query(_ name: String, _ type: ResourceRecordType = .host) -> Message {
    Message(id: 42, type: .query, questions: [Question(name: name, type: type)])
}

private func ipv4(_ response: Message?) -> IPv4Address? {
    (response?.answers.first as? HostRecord<IPv4Address>)?.ip
}

private let host = DNSQuerySource.ipv4(try! IPv4Address("127.0.0.1"))
private let guestOnDefault = DNSQuerySource.ipv4(try! IPv4Address("192.168.64.2"))
private let guestOnApp = DNSQuerySource.ipv4(try! IPv4Address("10.88.0.2"))
private let lanHost = DNSQuerySource.ipv4(try! IPv4Address("192.168.68.20"))

struct ContainerNameResolutionTests {
    private func networks() throws -> (FakeNetwork, FakeNetwork) {
        let defaultNetwork = try FakeNetwork(
            "default", subnet: "192.168.64.0/24",
            [
                try attachment("dnsa", on: "default", "192.168.64.2/24"),
                try attachment("web", on: "default", "192.168.64.3/24", aliases: ["www", "shared"]),
                try attachment("api", on: "default", "192.168.64.4/24", ipv6: "fd00::4/64", aliases: ["shared"]),
            ])
        let appNetwork = try FakeNetwork(
            "app", subnet: "10.88.0.0/24",
            [
                try attachment("worker", on: "app", "10.88.0.2/24"),
                try attachment("cache", on: "app", "10.88.0.3/24", aliases: ["web"]),
            ])
        return (defaultNetwork, appNetwork)
    }

    // MARK: The lookup passes

    @Test func aContainersOwnNameWinsOverAnotherContainersAliasOnAnyNetwork() async throws {
        let (defaultNetwork, appNetwork) = try networks()

        // "app" sorts first, and its cache is aliased "web"; the container called web still wins.
        let found = try await NetworksService.lookup(name: "web", on: [appNetwork, defaultNetwork])

        #expect(found?.hostname == "web")
    }

    @Test func anAliasResolvesToTheContainerHoldingIt() async throws {
        let (defaultNetwork, _) = try networks()

        #expect(try await NetworksService.lookup(name: "www", on: [defaultNetwork])?.hostname == "web")
    }

    @Test func aSharedAliasAnswersWithTheFirstHolderInNameOrder() async throws {
        let (defaultNetwork, _) = try networks()

        #expect(try await NetworksService.lookup(name: "shared", on: [defaultNetwork])?.hostname == "api")
    }

    @Test func aNameNobodyHoldsIsNotFound() async throws {
        let (defaultNetwork, appNetwork) = try networks()

        #expect(try await NetworksService.lookup(name: "nope", on: [defaultNetwork, appNetwork]) == nil)
        #expect(try await NetworksService.lookup(name: "nope", on: []) == nil)
    }

    @Test func aSenderBelongsToTheNetworkWhoseSubnetHoldsIt() throws {
        let subnets = ["default": try CIDRv4("192.168.64.0/24"), "app": try CIDRv4("10.88.0.0/24")]

        #expect(NetworksService.network(containing: try IPv4Address("192.168.64.9"), among: subnets) == "default")
        #expect(NetworksService.network(containing: try IPv4Address("10.88.0.9"), among: subnets) == "app")
        #expect(NetworksService.network(containing: try IPv4Address("192.168.68.20"), among: subnets) == nil)
        #expect(NetworksService.network(containing: try IPv4Address("10.88.0.9"), among: [:]) == nil)
    }

    // MARK: Who sees what

    @Test func theMacSeesEveryNetworkAGuestOnlyItsOwnAndStrangersNothing() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let table = ContainerNameTable(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        #expect(try await table.scope(for: host) == .all)
        #expect(try await table.scope(for: .ipv4(try IPv4Address("127.0.0.53"))) == .all)
        #expect(try await table.scope(for: guestOnDefault) == .view("default"))
        #expect(try await table.scope(for: guestOnApp) == .view("app"))
        #expect(try await table.scope(for: lanHost) == nil)
        #expect(try await table.scope(for: .other) == nil)
    }

    @Test func anEntryCarriesBothAddresses() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let table = ContainerNameTable(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        let api = try await table.entry(named: "api", in: .view("default"))
        let cacheFromDefault = try await table.entry(named: "cache", in: .view("default"))
        let cacheFromHost = try await table.entry(named: "cache", in: .all)

        #expect(api == HostTableEntry(ipv4: try IPv4Address("192.168.64.4"), ipv6: try IPv6Address("fd00::4")))
        #expect(cacheFromDefault == nil)
        #expect(cacheFromHost == HostTableEntry(ipv4: try IPv4Address("10.88.0.3")))
    }

    // MARK: The engine's resolver chain

    @Test func anEarlierContainerResolvesALaterOneAtTheTimeOfTheLookup() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        let before = try await resolver.answer(query: query("dnsb.container.internal."), from: guestOnDefault)
        #expect(before?.returnCode == .nonExistentDomain)

        defaultNetwork.attach(try attachment("dnsb", on: "default", "192.168.64.9/24", aliases: ["dnsb-alias"]))

        let bare = try await resolver.answer(query: query("dnsb."), from: guestOnDefault)
        let qualified = try await resolver.answer(query: query("dnsb.container.internal."), from: guestOnDefault)
        let alias = try await resolver.answer(query: query("dnsb-alias."), from: guestOnDefault)
        #expect(ipv4(bare) == (try IPv4Address("192.168.64.9")))
        #expect(ipv4(qualified) == (try IPv4Address("192.168.64.9")))
        #expect(ipv4(alias) == (try IPv4Address("192.168.64.9")))
        #expect(qualified?.id == 42)
    }

    @Test func aContainerRegisteredUnderTheConfiguredDomainResolvesQualified() async throws {
        // With `[dns] domain = "test"`, a container's first network registers "dnsweb.test.".
        let defaultNetwork = try FakeNetwork(
            "default", subnet: "192.168.64.0/24", [try attachment("dnsweb.test.", on: "default", "192.168.64.7/24")])
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork]))

        let fromHost = try await resolver.answer(query: query("dnsweb.test."), from: host)
        let fromGuest = try await resolver.answer(query: query("dnsweb.test."), from: guestOnDefault)

        #expect(ipv4(fromHost) == (try IPv4Address("192.168.64.7")))
        #expect(ipv4(fromGuest) == (try IPv4Address("192.168.64.7")))
    }

    @Test func aGuestOnAnotherNetworkGetsNXDomainForThatName() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        let response = try await resolver.answer(query: query("dnsa."), from: guestOnApp)

        #expect(response?.returnCode == .nonExistentDomain)
        #expect(response?.answers.isEmpty == true)
    }

    @Test func aNetworkAliasAnswersOnlyOnItsOwnNetwork() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        // On app, "web" is cache's alias; on default it is the container called web.
        #expect(ipv4(try await resolver.answer(query: query("web."), from: guestOnApp)) == (try IPv4Address("10.88.0.3")))
        #expect(ipv4(try await resolver.answer(query: query("web."), from: guestOnDefault)) == (try IPv4Address("192.168.64.3")))
    }

    @Test func aSenderOutsideEveryNetworkIsRefused() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        let response = try await resolver.answer(query: query("web."), from: lanHost)

        #expect(response?.returnCode == .refused)
        #expect(response?.answers.isEmpty == true)
    }

    @Test func aaaaIsNoDataForAContainerWithoutIPv6() async throws {
        let (defaultNetwork, appNetwork) = try networks()
        let resolver = ContainerNameTable.resolver(networks: FakeDirectory(networks: [defaultNetwork, appNetwork]))

        let web = try await resolver.answer(query: query("web.", .host6), from: guestOnDefault)
        let api = try await resolver.answer(query: query("api.", .host6), from: guestOnDefault)

        #expect(web?.returnCode == .noError)
        #expect(web?.answers.isEmpty == true)
        #expect((api?.answers.first as? HostRecord<IPv6Address>)?.ip == (try IPv6Address("fd00::4")))
    }
}
