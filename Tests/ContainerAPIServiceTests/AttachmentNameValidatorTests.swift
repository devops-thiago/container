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

import ContainerNetworkClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import DNSServer
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIService

struct AttachmentNameValidatorTests {
    @Test("Restored claims ignore all of the same container's attachments but never another owner's claim")
    func savedInventoryPreservesOwnerBoundaries() throws {
        let own = [
            attachment("owner.test", aliases: ["private.test", ".private.test", "shared.test"]),
            attachment("owner.test", network: "other", aliases: ["private.test", ".private.test", "shared.test"]),
        ]
        let peer = [attachment("peer.test", aliases: ["shared.test"])]
        let inventory = try AttachmentNameValidator.NamespaceInventory(containers: ["owner": own, "peer": peer])
        try AttachmentNameValidator.validateStored(id: "owner", networks: own, inventory: inventory, excluding: "owner")
        try AttachmentNameValidator.validateStored(id: "peer", networks: peer, inventory: inventory, excluding: "peer")

        let conflictingPeer = [attachment("peer.test", aliases: ["private.test"])]
        let conflict = try AttachmentNameValidator.NamespaceInventory(containers: ["owner": own, "peer": conflictingPeer])
        #expect(throws: ContainerizationError.self) {
            try AttachmentNameValidator.validateStored(id: "owner", networks: own, inventory: conflict, excluding: "owner")
        }
        #expect(throws: ContainerizationError.self) {
            try AttachmentNameValidator.validateStored(id: "peer", networks: conflictingPeer, inventory: conflict, excluding: "peer")
        }
        #expect(throws: ContainerizationError.self) {
            try AttachmentNameValidator.validateStored(
                id: "peer", networks: [attachment("OWNER.TEST.")], inventory: inventory, excluding: "peer")
        }
    }

    private func networks(_ fixture: EventServiceFixture, containers: ContainersService) async throws -> NetworksService {
        let plugin = "namespace-network-fixture"
        let directory = fixture.root.appendingPathComponent("plugins/\(plugin)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("bin/\(plugin)"))
        try Data(
            """
            abstract = "Namespace test network; never executed"
            [servicesConfig]
            loadAtBoot = false
            runAtLoad = false
            defaultArguments = []
            [[servicesConfig.services]]
            type = "network"
            """.utf8
        ).write(to: directory.appendingPathComponent("config.toml"))
        let configuration = try NetworkConfiguration(name: "default", mode: .nat, plugin: plugin)
        let networks = try await NetworksService(
            pluginLoader: fixture.loader(), resourceRoot: FilePath(fixture.root.appendingPathComponent("networks").path),
            containersService: containers, defaultNetworkConfiguration: configuration, log: fixture.log)
        let status = try NetworkStatus(ipv4Subnet: CIDRv4("192.168.129.0/24"), ipv4Gateway: IPv4Address("192.168.129.1"), ipv6Subnet: nil)
        await networks.setServiceState(
            key: configuration.id,
            value: .init(configuration: configuration, status: status, client: ContainerNetworkClient.NetworkClient(id: configuration.id, plugin: plugin)))
        await containers.setNetworksService(networks)
        return networks
    }

    @Test("Create and stored startup enforce namespace ownership without deleting workload data")
    func serviceChecksCreateAndStoredStartup() async throws {
        let fixture = EventServiceFixture()
        defer { fixture.cleanup() }
        let service = try fixture.service()
        var owner = fixture.configuration(id: "namespace-owner")
        owner.networks = [attachment("gateway.test")]
        try await fixture.create(service, owner)
        var peer = fixture.configuration(id: "namespace-peer")
        peer.networks = [attachment("peer.test", aliases: ["gateway.test", ".gateway.test"])]
        await #expect(throws: ContainerizationError.self) { try await fixture.create(service, peer) }
        #expect(try await service.list().map(\.id) == [owner.id])

        // Ordinary sharing still creates successfully. Simulate a stored configuration from
        // the vulnerable engine, then reload through the same bundle path as an engine restart.
        peer.networks = [attachment("peer.test", aliases: ["gateway.test"])]
        try await fixture.create(service, peer)
        let bundleURL = fixture.containers.appendingPathComponent(peer.id)
        let bundle = ContainerResource.Bundle(path: bundleURL)
        let sentinel = bundleURL.appendingPathComponent("workload-sentinel")
        try Data("keep my data".utf8).write(to: sentinel)
        peer.networks = [attachment("peer.test", aliases: ["gateway.test", ".gateway.test"])]
        try bundle.set(configuration: peer)
        let before = try Data(contentsOf: bundleURL.appendingPathComponent("config.json"))
        let reloaded = try fixture.service()
        let reloadedNetworks = try await networks(fixture, containers: reloaded)
        defer { withExtendedLifetime(reloadedNetworks) {} }
        let runtimesBefore = fixture.runtimeCount
        do {
            try await fixture.start(reloaded, peer.id)
            Issue.record("the stored namespace takeover started")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
            #expect(error.message.contains("network names"))
        }
        #expect(fixture.runtimeCount == runtimesBefore)
        #expect(try Data(contentsOf: sentinel) == Data("keep my data".utf8))
        #expect(try Data(contentsOf: bundleURL.appendingPathComponent("config.json")) == before)
        #expect(try await reloaded.list().count == 2)

        // Correcting only the offending alias makes the existing bundle usable again.
        peer.networks = [attachment("peer.test", aliases: ["gateway.test"])]
        try bundle.set(configuration: peer)
        let repaired = try fixture.service()
        let repairedNetworks = try await networks(fixture, containers: repaired)
        defer { withExtendedLifetime(repairedNetworks) {} }
        try await fixture.start(repaired, peer.id)
        #expect(try await repaired.list().first { $0.id == peer.id }?.status == .running)
        #expect(try Data(contentsOf: sentinel) == Data("keep my data".utf8))
    }

    @Test("Sharing an exact alias does not confer another container's subtree", arguments: [false, true])
    func sharedAliasCannotDelegateNamespace(existingIsAlias: Bool) {
        let existing =
            existingIsAlias
            ? attachment("peer.test", aliases: ["Gateway.Test."])
            : attachment("Gateway.Test.")
        expectError(.exists) {
            try validate([attachment("attacker.test", aliases: ["gateway.test", ".GATEWAY.test."])], existing: [existing])
        }
    }

    @Test("A private subtree root stays exclusive whichever claimant is created first", arguments: [false, true])
    func privateSubtreeCannotBeShared(asHostname: Bool) {
        let owner = attachment("owner.test", aliases: ["apps.test", ".apps.test"])
        let newcomer = asHostname ? attachment("APPS.TEST.") : attachment("peer.test", aliases: ["APPS.TEST."])
        expectError(.exists) { try validate([newcomer], existing: [owner]) }
    }

    @Test("A hostname retains its subtree authority when its exact name is shared")
    func hostnameAuthoritySurvivesSharedExactAlias() throws {
        try validate(
            [attachment("gateway.test", aliases: [".gateway.test"])],
            existing: [attachment("peer.test", aliases: ["gateway.test"])])
        try validate(
            [attachment("peer.test", aliases: ["gateway.test"])],
            existing: [attachment("gateway.test", aliases: [".gateway.test"])])
        try validate([attachment("owner.test", aliases: ["apps.test", ".apps.test"])])
    }

    private func attachment(_ hostname: String, network: String = "default", aliases: [String] = []) -> AttachmentConfiguration {
        AttachmentConfiguration(network: network, options: AttachmentOptions(hostname: hostname, aliases: aliases))
    }

    private func validate(_ networks: [AttachmentConfiguration], existing: [AttachmentConfiguration] = []) throws {
        try AttachmentNameValidator.validate(networks: networks, existing: existing)
    }

    private func expectError(_ code: ContainerizationError.Code, containing text: String? = nil, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected a \(code) error")
        } catch let error as ContainerizationError {
            #expect(error.code == code, "unexpected error: \(error)")
            if let text {
                #expect("\(error)".contains(text), "unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Hostnames

    @Test("Attachments without aliases and without conflicts are accepted")
    func noAliases() throws {
        try validate([attachment("foo.test.")], existing: [attachment("bar.test.")])
    }

    @Test("A hostname that an existing container uses is rejected")
    func hostnameConflict() {
        expectError(.exists, containing: "hostname(s) already exist") {
            try validate([attachment("foo.test.")], existing: [attachment("foo.test.")])
        }
    }

    @Test("Hostnames are compared without regard to case or a trailing dot")
    func hostnameConflictNormalized() {
        expectError(.exists) {
            try validate([attachment("Foo.Test.")], existing: [attachment("foo.test")])
        }
    }

    @Test("A hostname that an existing container has as an exact alias is accepted, as Docker accepts it")
    func hostnameMatchesAnotherContainersAlias() throws {
        try validate(
            [attachment("api.test.")],
            existing: [attachment("foo.test.", aliases: ["api.test"])]
        )
    }

    @Test("A hostname below an existing subtree alias is accepted")
    func hostnameBelowSubtree() throws {
        try validate(
            [attachment("web.foo.test.")],
            existing: [attachment("foo.test.", aliases: [".foo.test"])]
        )
    }

    // MARK: - Exact aliases

    @Test("An exact alias that nothing else claims is accepted")
    func exactAlias() throws {
        try validate(
            [attachment("foo.test.", aliases: ["api.test", "Other.Test."])],
            existing: [attachment("bar.test.")]
        )
    }

    @Test("An exact alias that matches another container's hostname is accepted, as Docker accepts it")
    func aliasMatchesAnotherContainersHostname() throws {
        try validate(
            [attachment("foo.test.", aliases: ["bar.test"])],
            existing: [attachment("bar.test.")]
        )
    }

    @Test("An exact alias another container holds is shared, as Compose replicas share a service name")
    func aliasSharedWithAnotherContainer() throws {
        try validate(
            [attachment("web-2", aliases: ["web"])],
            existing: [attachment("web-1", aliases: ["web"])]
        )
        try validate(
            [attachment("foo.test.", aliases: ["API.test."])],
            existing: [attachment("bar.test.", aliases: ["api.test"])]
        )
    }

    @Test("An exact alias that repeats the container's own hostname is accepted and adds nothing")
    func aliasMatchesOwnHostname() throws {
        try validate([attachment("foo.test.", aliases: ["foo.test"])])
    }

    @Test("An exact alias that matches the hostname of another attachment of the container is accepted")
    func aliasMatchesOtherOwnHostname() throws {
        try validate([
            attachment("foo.test.", aliases: ["bar.test"]),
            attachment("bar.test", network: "other"),
        ])
    }

    @Test("The same exact alias on two networks is accepted, as --network-alias gives every network")
    func aliasOnTwoNetworks() throws {
        try validate([
            attachment("foo.test.", aliases: ["api.test"]),
            attachment("foo", network: "other", aliases: ["api.test"]),
        ])
    }

    @Test("An exact alias with a single label is accepted, as Docker accepts a service name", arguments: ["api", "API.", "localhost"])
    func unqualifiedExactAlias(alias: String) throws {
        try validate([attachment("foo.test.", aliases: [alias])])
    }

    @Test("An exact alias with two labels is accepted")
    func qualifiedExactAlias() throws {
        try validate([attachment("foo.test.", aliases: ["api.test"])])
    }

    @Test("An alias listed twice is rejected")
    func duplicateAlias() {
        expectError(.invalidArgument, containing: "more than once") {
            try validate([attachment("foo.test.", aliases: ["api.test", "API.test."])])
        }
    }

    // MARK: - Malformed aliases and limits

    @Test("Malformed aliases are rejected", arguments: ["", ".", "..", "exa mple.test", "-bad.test", "a..b"])
    func malformedAlias(alias: String) {
        expectError(.invalidArgument, containing: "invalid alias") {
            try validate([attachment("foo.test.", aliases: [alias])])
        }
    }

    @Test("An asterisk is rejected with a hint about the leading dot")
    func asterisk() {
        expectError(.invalidArgument, containing: "leading dot") {
            try validate([attachment("foo.test.", aliases: ["*.foo.test"])])
        }
    }

    @Test("The alias limit is enforced per attachment")
    func aliasLimit() throws {
        let limit = AttachmentNameValidator.maximumAliasesPerAttachment
        let atLimit = (0..<limit).map { "alias\($0).test" }
        try validate([attachment("foo.test.", aliases: atLimit)])

        expectError(.invalidArgument, containing: "at most") {
            try validate([attachment("foo.test.", aliases: atLimit + ["one-more.test"])])
        }
    }

    // MARK: - Subtree aliases

    @Test("A subtree alias below the attachment's hostname is accepted")
    func subtreeBelowHostname() throws {
        try validate([attachment("gateway.test.", aliases: [".gateway.test"])])
    }

    @Test("A subtree alias below an exact alias of the attachment is accepted")
    func subtreeBelowAlias() throws {
        try validate([attachment("foo.test.", aliases: ["apps.test", ".apps.test"])])
    }

    @Test("A subtree alias below a name the attachment does not own is rejected")
    func subtreeNotOwned() {
        expectError(.invalidArgument, containing: "neither") {
            try validate([attachment("foo.test.", aliases: [".apps.test"])])
        }
    }

    @Test("A subtree alias below another container's hostname is rejected")
    func subtreeBelowOtherContainer() {
        expectError(.invalidArgument, containing: "neither") {
            try validate(
                [attachment("foo.test.", aliases: [".gateway.test"])],
                existing: [attachment("gateway.test.")]
            )
        }
    }

    @Test("A subtree alias below another attachment's hostname is rejected")
    func subtreeBelowOtherAttachment() {
        expectError(.invalidArgument, containing: "neither") {
            try validate([
                attachment("foo.test.", aliases: [".bar.test"]),
                attachment("bar.test", network: "other"),
            ])
        }
    }

    @Test("A subtree alias whose base has a single label is rejected even when the container owns it")
    func subtreeSingleLabelBase() {
        expectError(.invalidArgument, containing: "at least 2 labels") {
            try validate([attachment("test", aliases: [".test"])])
        }
    }

    @Test("A subtree alias is compared to the hostname without regard to case or a trailing dot")
    func subtreeNormalized() throws {
        try validate([attachment("Gateway.Test.", aliases: [".GATEWAY.test."])])
    }

    @Test("Two containers cannot both own the same base, so they cannot share a subtree")
    func subtreeCannotBeShared() {
        expectError(.exists, containing: "hostname(s) already exist") {
            try validate(
                [attachment("gateway.test.", aliases: [".gateway.test"])],
                existing: [attachment("gateway.test.", aliases: [".gateway.test"])]
            )
        }
    }

    @Test("Nested subtrees rooted at names their own containers own are accepted")
    func nestedSubtrees() throws {
        try validate(
            [attachment("apps.gateway.test.", aliases: [".apps.gateway.test"])],
            existing: [attachment("gateway.test.", aliases: [".gateway.test"])]
        )
    }

    @Test("Stopped and running containers are treated alike because the caller passes all of them")
    func existingIncludesEveryContainer() {
        expectError(.exists) {
            try validate(
                [attachment("b.test.")],
                existing: [attachment("a.test."), attachment("b.test.", aliases: ["api.test"])]
            )
        }
    }

    @Test("A stored configuration that follows the rules is accepted")
    func storedValid() throws {
        try AttachmentNameValidator.validateStored(
            id: "gateway",
            networks: [attachment("gateway.test.", aliases: ["api.test", ".gateway.test"])], existing: []
        )
    }

    @Test("A stored configuration without aliases is accepted")
    func storedWithoutAliases() throws {
        try AttachmentNameValidator.validateStored(id: "foo", networks: [attachment("foo.test.")], existing: [])
    }

    @Test("A stored subtree alias below a name the attachment does not own is left out, not honoured")
    func storedUnownedSubtree() throws {
        try AttachmentNameValidator.validateStored(
            id: "victim",
            networks: [attachment("victim.test.", aliases: [".com.example"])], existing: []
        )
        let rules = try AliasPolicy.validate(
            aliases: [".com.example"], hostname: try DNSName("victim.test"), network: "default", tolerant: true)
        #expect(rules.isEmpty)
    }

    @Test("A stored alias an earlier engine accepted but today's rules do not still lets the container start")
    func storedMalformed() throws {
        try AttachmentNameValidator.validateStored(
            id: "legacy",
            networks: [attachment("legacy", aliases: ["*.victim.test", "_internal", "db"])], existing: []
        )
        let rules = try AliasPolicy.validate(
            aliases: ["*.victim.test", "_internal", "db"], hostname: try DNSName("legacy"), network: "default", tolerant: true)
        #expect(rules.map(\.description) == ["db"])
    }

    @Test("A stored configuration with more aliases than a new one may have still starts")
    func storedTooMany() throws {
        let aliases = (0...AttachmentNameValidator.maximumAliasesPerAttachment).map { "alias\($0).test" }
        try AttachmentNameValidator.validateStored(id: "legacy", networks: [attachment("legacy.test.", aliases: aliases)], existing: [])
    }

    @Test("A stored alias that is also a hostname of the container is accepted")
    func storedAliasIsHostname() throws {
        try AttachmentNameValidator.validateStored(
            id: "victim",
            networks: [
                attachment("victim.test.", aliases: ["db.test"]),
                attachment("db.test", network: "other"),
            ], existing: []
        )
    }

    @Test("A 1.6.0-shaped stored configuration whose alias another container shares starts")
    func storedSharedAlias() throws {
        // As SiliconShip 1.6.0 stored a Compose service: a bare service name, on every network.
        let stored = [
            attachment("shop-web-2", aliases: ["web", "shop-web-2"]),
            attachment("shop-web-2", network: "frontend", aliases: ["web"]),
        ]
        try AttachmentNameValidator.validateStored(
            id: "shop-web-2", networks: stored,
            existing: [attachment("shop-web-1", aliases: ["web"])])
    }
}
