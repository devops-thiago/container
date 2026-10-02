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
import Foundation
import Testing

@testable import ContainerAPIClient

struct NetworkAliasTests {
    @Test("--network takes alias= properties, each a host name")
    func grammar() throws {
        let parsed = try Parser.network("backend,alias=db,mtu=1500,alias=postgres.internal")
        #expect(parsed.name == "backend")
        #expect(parsed.aliases == ["db", "postgres.internal"])
        #expect(parsed.mtu == 1500)
        #expect(try Parser.network("backend").aliases.isEmpty)
        #expect(throws: ContainerizationError.self) { try Parser.network("backend,alias=") }
        #expect(throws: ContainerizationError.self) { try Parser.network("backend,alias=not a name") }
        #expect(throws: ContainerizationError.self) { try Parser.network("backend,alias=-db") }
    }

    @Test("an alias is a host name: underscores pass, as they do in a container's name")
    func aliasCharacters() throws {
        for alias in ["db", "db_primary", "_internal", "db-1.stack_a.internal", "A1"] {
            #expect(try Parser.networkAlias(alias) == alias)
        }
        let label = String(repeating: "a", count: 63)
        #expect(try Parser.networkAlias(label) == label)
        for alias in ["", "-db", "db-", "a..b", ".db", "db.", "two words", "db,primary", "db/primary", label + "a"] {
            #expect(throws: ContainerizationError.self, "\(alias)") { try Parser.networkAlias(alias) }
        }
    }

    @Test("--network-alias is a flag of run and create, no longer one that is ignored")
    func flag() throws {
        let management = try Flags.Management.parse(["--network", "backend", "--network-alias", "db", "--network-alias", "primary"])
        #expect(management.networkAliases == ["db", "primary"])
        let unsupported = try Flags.Unsupported.parse([])
        #expect(!unsupported.given.contains("--network-alias"))
    }

    @Test("an alias given for every network follows a network's own, once")
    func attachmentConfigurations() throws {
        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "shop-db-1", builtinNetworkId: "default",
            networks: [try Parser.network("backend,alias=db"), try Parser.network("metrics,alias=shared")],
            dnsDomain: nil, aliases: ["shared", "postgres"])
        #expect(attachments.map(\.network) == ["backend", "metrics"])
        #expect(attachments[0].options.aliases == ["db", "shared", "postgres"])
        #expect(attachments[1].options.aliases == ["shared", "postgres"])

        let builtin = try Utility.getAttachmentConfigurations(
            containerId: "web", builtinNetworkId: "default", networks: [], dnsDomain: nil, aliases: ["frontend"])
        #expect(builtin.count == 1)
        #expect(builtin[0].options.aliases == ["frontend"])

        let plain = try Utility.getAttachmentConfigurations(containerId: "web", builtinNetworkId: "default", networks: [], dnsDomain: nil)
        #expect(plain[0].options.aliases.isEmpty)
    }

    @Test("configurations and attachments stored before aliases decode with none, and encode none when empty")
    func compatibility() throws {
        let options = try JSONDecoder().decode(AttachmentOptions.self, from: Data(#"{"hostname":"web","mtu":1280}"#.utf8))
        #expect(options.aliases.isEmpty)
        #expect(options.hostname == "web")
        #expect(options.mtu == 1280)
        let plain = String(decoding: try JSONEncoder().encode(AttachmentOptions(hostname: "web")), as: UTF8.self)
        #expect(!plain.contains("aliases"))
        let aliased = try JSONDecoder().decode(
            AttachmentOptions.self, from: try JSONEncoder().encode(AttachmentOptions(hostname: "web", aliases: ["frontend"])))
        #expect(aliased.aliases == ["frontend"])

        let attachment = try Attachment(
            network: "default", hostname: "web", ipv4Address: CIDRv4("192.0.2.10/24"), ipv4Gateway: IPv4Address("192.0.2.1"),
            ipv6Address: nil, macAddress: nil, aliases: ["frontend"])
        let decoded = try JSONDecoder().decode(Attachment.self, from: try JSONEncoder().encode(attachment))
        #expect(decoded.aliases == ["frontend"])
        let old = try JSONDecoder().decode(
            Attachment.self,
            from: Data(#"{"network":"default","hostname":"web","ipv4Address":"192.0.2.10/24","ipv4Gateway":"192.0.2.1"}"#.utf8))
        #expect(old.aliases.isEmpty)
    }
}
