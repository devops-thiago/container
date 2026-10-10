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
import Synchronization
import Testing

@testable import DNSServer

/// A table with one view per network and a fixed scope per sender, which records every
/// lookup so a test can see which part of the table a query was answered from.
final class FakeScopedTable: ScopedHostTable, Sendable {
    let views: [String: [String: HostTableEntry]]
    let scopes: [DNSQuerySource: HostTableScope]
    private let asked = Mutex<[(String, HostTableScope)]>([])

    init(views: [String: [String: HostTableEntry]], scopes: [DNSQuerySource: HostTableScope]) {
        self.views = views
        self.scopes = scopes
    }

    var lookups: [(String, HostTableScope)] { asked.withLock { $0 } }

    func scope(for source: DNSQuerySource) async throws -> HostTableScope? {
        scopes[source]
    }

    func entry(named name: String, in scope: HostTableScope) async throws -> HostTableEntry? {
        asked.withLock { $0.append((name, scope)) }
        switch scope {
        case .all:
            return views.keys.sorted().lazy.compactMap { self.views[$0]?[name] }.first
        case .view(let view):
            return views[view]?[name]
        }
    }
}

struct ScopedHostTableResolverTest {
    static let host = DNSQuerySource.ipv4(try! IPv4Address("127.0.0.1"))
    static let guestOnA = DNSQuerySource.ipv4(try! IPv4Address("192.168.64.2"))
    static let guestOnB = DNSQuerySource.ipv4(try! IPv4Address("10.88.0.2"))
    static let stranger = DNSQuerySource.ipv4(try! IPv4Address("192.168.68.20"))

    static func table() throws -> FakeScopedTable {
        FakeScopedTable(
            views: [
                "net-a": [
                    "web": HostTableEntry(ipv4: try IPv4Address("192.168.64.3")),
                    "db": HostTableEntry(ipv4: try IPv4Address("192.168.64.4"), ipv6: try IPv6Address("fd00::4")),
                ],
                "net-b": [
                    "cache": HostTableEntry(ipv4: try IPv4Address("10.88.0.3"))
                ],
            ],
            scopes: [host: .all, guestOnA: .view("net-a"), guestOnB: .view("net-b")]
        )
    }

    static func query(_ name: String, _ type: ResourceRecordType = .host) -> Message {
        Message(id: 7, type: .query, questions: [Question(name: name, type: type)])
    }

    @Test func aGuestResolvesAPeerOnItsNetworkByBareName() async throws {
        let table = try Self.table()
        let response = try await ScopedHostTableResolver(table: table).answer(query: Self.query("web."), from: Self.guestOnA)

        #expect(response?.returnCode == .noError)
        #expect(response?.id == 7)
        #expect(response?.answers.count == 1)
        let record = response?.answers.first as? HostRecord<IPv4Address>
        #expect(record?.ip == (try IPv4Address("192.168.64.3")))
        #expect(record?.name == "web.")
        #expect(record?.ttl == 5)
        #expect(table.lookups.map(\.1) == [.view("net-a")])
    }

    @Test func aSearchDomainQualifiedNameFallsBackToItsFirstLabel() async throws {
        let table = try Self.table()
        let response = try await ScopedHostTableResolver(table: table)
            .answer(query: Self.query("web.container.internal."), from: Self.guestOnA)

        let record = response?.answers.first as? HostRecord<IPv4Address>
        #expect(record?.ip == (try IPv4Address("192.168.64.3")))
        #expect(record?.name == "web.container.internal.")
        #expect(table.lookups.map(\.0) == ["web.container.internal", "web.container.internal.", "web"])
    }

    @Test func aNameRegisteredFullyQualifiedResolvesAsAsked() async throws {
        let table = FakeScopedTable(
            views: ["net-a": ["web.test.": HostTableEntry(ipv4: try IPv4Address("192.168.64.3"))]],
            scopes: [Self.host: .all])
        let response = try await ScopedHostTableResolver(table: table).answer(query: Self.query("web.test."), from: Self.host)

        #expect((response?.answers.first as? HostRecord<IPv4Address>)?.ip == (try IPv4Address("192.168.64.3")))
    }

    @Test func aGuestDoesNotSeeContainersOnAnotherNetwork() async throws {
        let table = try Self.table()
        let resolver = ScopedHostTableResolver(table: table)

        #expect(try await resolver.answer(query: Self.query("cache."), from: Self.guestOnA) == nil)
        #expect(try await resolver.answer(query: Self.query("web."), from: Self.guestOnB) == nil)
    }

    @Test func theHostSeesEveryNetwork() async throws {
        let table = try Self.table()
        let resolver = ScopedHostTableResolver(table: table)

        let web = try await resolver.answer(query: Self.query("web.test."), from: Self.host)
        let cache = try await resolver.answer(query: Self.query("cache."), from: Self.host)

        #expect((web?.answers.first as? HostRecord<IPv4Address>)?.ip == (try IPv4Address("192.168.64.3")))
        #expect((cache?.answers.first as? HostRecord<IPv4Address>)?.ip == (try IPv4Address("10.88.0.3")))
        #expect(table.lookups.allSatisfy { $0.1 == .all })
    }

    @Test func aMissIsLeftToTheNextHandler() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Self.query("nope.container.internal."), from: Self.guestOnA)

        #expect(response == nil)
    }

    @Test func aSenderTheTableDoesNotServeIsRefusedWithoutALookup() async throws {
        let table = try Self.table()
        let resolver = ScopedHostTableResolver(table: table)

        let stranger = try await resolver.answer(query: Self.query("web."), from: Self.stranger)
        let unknown = try await resolver.answer(query: Self.query("web."), from: .other)
        let sourceless = try await resolver.answer(query: Self.query("web."))

        for response in [stranger, unknown, sourceless] {
            #expect(response?.returnCode == .refused)
            #expect(response?.answers.isEmpty == true)
            #expect(response?.questions.first?.name == "web.")
        }
        #expect(table.lookups.isEmpty)
    }

    @Test func aaaaAnswersTheIPv6AddressWhenThereIsOne() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Self.query("db.", .host6), from: Self.guestOnA)

        #expect(response?.returnCode == .noError)
        #expect((response?.answers.first as? HostRecord<IPv6Address>)?.ip == (try IPv6Address("fd00::4")))
    }

    @Test func aaaaIsNoDataForAKnownNameWithoutIPv6() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Self.query("web.", .host6), from: Self.guestOnA)

        #expect(response?.returnCode == .noError)
        #expect(response?.answers.isEmpty == true)
    }

    @Test func aaaaForAnUnknownNameIsLeftToTheNextHandler() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Self.query("nope.", .host6), from: Self.guestOnA)

        #expect(response == nil)
    }

    @Test func otherRecordTypesAreNotImplemented() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Self.query("web.", .mailExchange), from: Self.guestOnA)

        #expect(response?.returnCode == .notImplemented)
    }

    @Test func aQueryWithNoQuestionIsNotAnswered() async throws {
        let response = try await ScopedHostTableResolver(table: try Self.table())
            .answer(query: Message(id: 1, type: .query, questions: []), from: Self.guestOnA)

        #expect(response == nil)
    }
}
