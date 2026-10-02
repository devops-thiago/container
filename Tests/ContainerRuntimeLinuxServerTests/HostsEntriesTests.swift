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
import ContainerizationError
import ContainerizationExtras
import Testing

@testable import ContainerRuntimeLinuxServer

struct HostsEntriesTests {
    private func peer(_ name: String) throws -> ContainerResource.Attachment {
        try ContainerResource.Attachment(
            network: "test", hostname: name, ipv4Address: CIDRv4("192.0.2.20/24"),
            ipv4Gateway: IPv4Address("192.0.2.1"), ipv6Address: nil, macAddress: nil)
    }

    @Test func extraHostsReplacePeerAliasesWithoutLosingOtherNames() throws {
        let entries = try RuntimeService.hostsEntries(
            hostname: "self", primaryAddress: "192.0.2.10", peers: [peer("database"), peer("web")], searchDomain: "container.internal",
            extraHosts: [.init(name: "DATABASE", address: "192.0.2.99"), .init(name: "web.container.internal", address: "2001:db8::2")], gateway: "192.0.2.1")
        let bareDatabase = entries.filter { $0.hostnames.contains { $0.lowercased() == "database" } }
        #expect(bareDatabase.map(\.ipAddress) == ["192.0.2.99"])
        let qualifiedWeb = entries.filter { $0.hostnames.contains("web.container.internal") }
        #expect(qualifiedWeb.map(\.ipAddress) == ["2001:db8::2"])
        #expect(entries.contains { $0.hostnames == ["database.container.internal"] && $0.ipAddress == "192.0.2.20" })
        #expect(entries.contains { $0.hostnames == ["web"] && $0.ipAddress == "192.0.2.20" })
        #expect(entries.first?.rendered == "127.0.0.1 localhost")
        #expect(entries.contains { $0.rendered == "192.0.2.10 self" })
    }

    @Test func dropsPeerEntryWhenEveryAliasIsOverridden() throws {
        let entries = try RuntimeService.hostsEntries(
            hostname: "self", primaryAddress: nil, peers: [peer("database")], searchDomain: "container.internal",
            extraHosts: [.init(name: "database", address: "192.0.2.99"), .init(name: "database.container.internal", address: "192.0.2.99")], gateway: nil)
        #expect(!entries.contains { $0.ipAddress == "192.0.2.20" })
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { !$0.hostnames.isEmpty })
    }

    @Test func resolvesHostGatewayUsingInjectedFirstNetworkGateway() throws {
        let entries = try RuntimeService.hostsEntries(
            hostname: "self", primaryAddress: nil, peers: [], searchDomain: "container.internal",
            extraHosts: [.init(name: "host.docker.internal", address: "host-gateway"), .init(name: "literal", address: "2001:db8::8")], gateway: "198.51.100.1")
        #expect(entries.map(\.rendered) == ["127.0.0.1 localhost", "198.51.100.1 host.docker.internal", "2001:db8::8 literal"])
    }

    @Test func missingGatewayIsStillRejectedByRuntime() throws {
        #expect(throws: ContainerizationError.self) {
            try RuntimeService.hostsEntries(
                hostname: "self", primaryAddress: nil, peers: [], searchDomain: "container.internal",
                extraHosts: [.init(name: "host.docker.internal", address: "host-gateway")], gateway: nil)
        }
        let entries = try RuntimeService.hostsEntries(
            hostname: "self", primaryAddress: nil, peers: [], searchDomain: "container.internal",
            extraHosts: [.init(name: "literal", address: "192.0.2.2")], gateway: nil)
        #expect(entries.last?.rendered == "192.0.2.2 literal")
    }

    @Test func aliasesFollowAPeersOwnNamesAndTheContainersToo() throws {
        let database = try ContainerResource.Attachment(
            network: "test", hostname: "shop-db-1", ipv4Address: CIDRv4("192.0.2.30/24"),
            ipv4Gateway: IPv4Address("192.0.2.1"), ipv6Address: nil, macAddress: nil, aliases: ["db", "shop-db-1", "postgres"])
        let entries = try RuntimeService.hostsEntries(
            hostname: "shop-web-1", aliases: ["web", "shop-web-1"], primaryAddress: "192.0.2.10", peers: [database, peer("cache")],
            searchDomain: "container.internal", extraHosts: [], gateway: "192.0.2.1")
        #expect(
            entries.map(\.rendered) == [
                "127.0.0.1 localhost",
                "192.0.2.10 shop-web-1 web",
                "192.0.2.30 shop-db-1 shop-db-1.container.internal db postgres",
                "192.0.2.20 cache cache.container.internal",
            ])
    }

    @Test func anExplicitHostStillWinsOverAPeersAlias() throws {
        let database = try ContainerResource.Attachment(
            network: "test", hostname: "shop-db-1", ipv4Address: CIDRv4("192.0.2.30/24"),
            ipv4Gateway: IPv4Address("192.0.2.1"), ipv6Address: nil, macAddress: nil, aliases: ["db"])
        let entries = try RuntimeService.hostsEntries(
            hostname: "self", primaryAddress: nil, peers: [database], searchDomain: "container.internal",
            extraHosts: [.init(name: "db", address: "192.0.2.99")], gateway: nil)
        #expect(entries.filter { $0.hostnames.contains("db") }.map(\.ipAddress) == ["192.0.2.99"])
        #expect(entries.contains { $0.rendered == "192.0.2.30 shop-db-1 shop-db-1.container.internal" })
    }
}
