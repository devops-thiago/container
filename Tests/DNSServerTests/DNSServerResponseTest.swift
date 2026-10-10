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

import ContainerizationExtras
import Foundation
import NIOCore
import Testing

@testable import DNSServer

/// The server's wire path, from query bytes and a sender to response bytes, with the
/// container-name chain behind it.
struct DNSServerResponseTest {
    static func server() throws -> DNSServer {
        DNSServer(
            handler: StandardQueryValidator(
                handler: CompositeResolver(handlers: [
                    ScopedHostTableResolver(table: try ScopedHostTableResolverTest.table()),
                    NxDomainResolver(),
                ])))
    }

    static func wire(_ name: String, _ type: ResourceRecordType = .host) throws -> Data {
        try ScopedHostTableResolverTest.query(name, type).serialize()
    }

    static func answerCount(_ data: Data) -> Int {
        Int(data[data.startIndex + 6]) << 8 | Int(data[data.startIndex + 7])
    }

    @Test func theSenderReachesTheHandlerThroughTheChain() async throws {
        let server = try Self.server()

        let onItsNetwork = try await server.response(to: Self.wire("web.container.internal."), from: ScopedHostTableResolverTest.guestOnA)
        let onAnother = try await server.response(to: Self.wire("web.container.internal."), from: ScopedHostTableResolverTest.guestOnB)

        #expect(try Message(deserialize: onItsNetwork).returnCode == .noError)
        #expect(Self.answerCount(onItsNetwork) == 1)
        #expect(try Message(deserialize: onAnother).returnCode == .nonExistentDomain)
        #expect(Self.answerCount(onAnother) == 0)
    }

    @Test func aRefusalStaysARefusalOnTheWire() async throws {
        let response = try await Self.server().response(to: Self.wire("web."), from: ScopedHostTableResolverTest.stranger)

        let message = try Message(deserialize: response)
        #expect(message.returnCode == .refused)
        #expect(message.id == 7)
        #expect(Self.answerCount(response) == 0)
    }

    @Test func aMissIsNXDomainAndNoDataStaysNoError() async throws {
        let server = try Self.server()

        let miss = try await server.response(to: Self.wire("nope."), from: ScopedHostTableResolverTest.guestOnA)
        let missAAAA = try await server.response(to: Self.wire("nope.", .host6), from: ScopedHostTableResolverTest.guestOnA)
        let noData = try await server.response(to: Self.wire("web.", .host6), from: ScopedHostTableResolverTest.guestOnA)

        #expect(try Message(deserialize: miss).returnCode == .nonExistentDomain)
        #expect(try Message(deserialize: missAAAA).returnCode == .nonExistentDomain)
        #expect(try Message(deserialize: noData).returnCode == .noError)
        #expect(Self.answerCount(noData) == 0)
    }

    @Test func theSourceIsReadFromTheSendersSocketAddress() throws {
        let v4 = try SocketAddress(ipAddress: "192.168.64.2", port: 53000)
        let v6 = try SocketAddress(ipAddress: "fd00::2", port: 53000)
        let unix = try SocketAddress(unixDomainSocketPath: "/tmp/dns.sock")

        #expect(DNSQuerySource(v4) == .ipv4(try IPv4Address("192.168.64.2")))
        #expect(DNSQuerySource(v6) == .other)
        #expect(DNSQuerySource(unix) == .other)
    }
}
