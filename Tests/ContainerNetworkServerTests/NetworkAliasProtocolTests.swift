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
import ContainerXPC
import ContainerizationExtras
import Testing

@testable import ContainerNetworkClient
@testable import ContainerNetworkServer

struct NetworkAliasProtocolTests {
    private func message() -> XPCMessage {
        XPCMessage(route: "test")
    }

    // MARK: - Aliases in messages

    @Test func testAliasesRoundTrip() throws {
        let message = message()
        try message.setAliases(["api.example.test", ".example.test"])

        #expect(try message.aliases() == ["api.example.test", ".example.test"])
    }

    @Test func testMessageWithoutAliasesHasNone() throws {
        #expect(try message().aliases().isEmpty)
    }

    // MARK: - Match kind in messages

    @Test func testMatchKindRoundTrip() throws {
        let kinds: [NetworkMatchKind] = [.hostname, .alias, .subtree(baseLabelCount: 3)]
        for kind in kinds {
            let message = message()
            message.setMatchKind(kind)
            #expect(try message.matchKind() == kind)
        }
    }

    @Test func testMessageWithoutMatchKindIsRejected() {
        #expect(throws: (any Error).self) {
            try message().matchKind()
        }
    }

    @Test func testUnknownMatchKindIsRejected() throws {
        let message = message()
        message.set(key: NetworkKeys.matchKind.rawValue, value: "wildcard")

        #expect(throws: (any Error).self) {
            try message.matchKind()
        }
    }

    // MARK: - Name in messages

    @Test func testNameRoundTrip() throws {
        let message = message()
        message.set(key: NetworkKeys.name.rawValue, value: "web.example.test.")

        #expect(try message.name() == "web.example.test.")
    }

    @Test func testMessageWithoutNameIsRejected() {
        #expect(throws: (any Error).self) {
            try message().name()
        }
    }

    // MARK: - Lookups that answer with every holder of a shared alias

    private func attachment(_ hostname: String, _ address: String) throws -> ContainerResource.Attachment {
        try ContainerResource.Attachment(
            network: "backend", hostname: hostname, ipv4Address: CIDRv4(address), ipv4Gateway: IPv4Address("192.0.2.1"),
            ipv6Address: nil, macAddress: nil, aliases: ["web"])
    }

    @Test func testASharedAliasCarriesEveryHolderToTheClient() throws {
        let reply = message()
        let matches = [
            NetworkMatch(attachment: try attachment("shop-web-1", "192.0.2.10/24"), kind: .alias),
            NetworkMatch(attachment: try attachment("shop-web-2", "192.0.2.11/24"), kind: .alias),
        ]
        try NetworkHarness.setMatches(matches, on: reply)

        let decoded = try NetworkClient.matches(from: reply)
        #expect(decoded.map(\.attachment.hostname) == ["shop-web-1", "shop-web-2"])
        #expect(decoded.map(\.attachment.ipv4Address.address.description) == ["192.0.2.10", "192.0.2.11"])
        #expect(decoded.allSatisfy { $0.kind == .alias })
    }

    @Test func testASingleMatchStaysTheReplyAnOlderClientReads() throws {
        let reply = message()
        try NetworkHarness.setMatches([NetworkMatch(attachment: try attachment("shop-db-1", "192.0.2.30/24"), kind: .hostname)], on: reply)

        #expect(reply.dataNoCopy(key: NetworkKeys.attachments.rawValue) == nil)
        #expect(try NetworkClient.matches(from: reply).map(\.attachment.hostname) == ["shop-db-1"])
        #expect(try NetworkClient.matches(from: message()).isEmpty)
    }
}
