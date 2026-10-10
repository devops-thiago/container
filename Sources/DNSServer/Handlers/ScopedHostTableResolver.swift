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

/// The part of a ``ScopedHostTable`` one sender may see.
public enum HostTableScope: Sendable, Equatable {
    /// Every registered name.
    case all
    /// Only the names registered in one view, such as the containers on one network.
    case view(String)
}

/// The addresses a registered name resolves to.
public struct HostTableEntry: Sendable, Equatable {
    public let ipv4: IPv4Address
    public let ipv6: IPv6Address?

    public init(ipv4: IPv4Address, ipv6: IPv6Address? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

/// A name table that answers each sender from its own part of the table.
public protocol ScopedHostTable: Sendable {
    /// What `source` may look up, or nil for a sender the table does not serve.
    func scope(for source: DNSQuerySource) async throws -> HostTableScope?

    /// The entry registered under `name` within `scope`, or nil when there is none. `name`
    /// is one spelling of the question's name: without the root dot, as asked (with it), or
    /// its first label.
    func entry(named name: String, in scope: HostTableScope) async throws -> HostTableEntry?
}

/// Answers A and AAAA questions from a ``ScopedHostTable``, refusing senders it does not serve.
///
/// A name it does not know is not answered at all (nil), so a resolver behind it in a
/// ``CompositeResolver`` decides — NXDOMAIN, in the container resolver's chain.
public struct ScopedHostTableResolver: DNSHandler {
    private let table: any ScopedHostTable
    private let ttl: UInt32

    public init(table: any ScopedHostTable, ttl: UInt32 = 5) {
        self.table = table
        self.ttl = ttl
    }

    /// A query with no known sender is answered as one from a sender the table may not serve.
    public func answer(query: Message) async throws -> Message? {
        try await answer(query: query, from: .other)
    }

    public func answer(query: Message, from source: DNSQuerySource) async throws -> Message? {
        guard let question = query.questions.first else {
            return nil
        }
        guard let scope = try await table.scope(for: source) else {
            return Message(id: query.id, type: .response, returnCode: .refused, questions: query.questions, answers: [])
        }

        let record: ResourceRecord?
        switch question.type {
        case ResourceRecordType.host:
            guard let entry = try await entry(for: question, in: scope) else {
                return nil
            }
            record = HostRecord<IPv4Address>(name: question.name, ttl: ttl, ip: entry.ipv4)
        case ResourceRecordType.host6:
            guard let entry = try await entry(for: question, in: scope) else {
                return nil
            }
            // NODATA (noError with no answers) when the name exists without an IPv6 address.
            // musl treats NXDOMAIN on AAAA as "the name does not exist" and fails the whole
            // lookup even though the A query succeeded.
            record = entry.ipv6.map { HostRecord<IPv6Address>(name: question.name, ttl: ttl, ip: $0) }
        default:
            return Message(id: query.id, type: .response, returnCode: .notImplemented, questions: query.questions, answers: [])
        }

        return Message(
            id: query.id,
            type: .response,
            returnCode: .noError,
            questions: query.questions,
            answers: record.map { [$0] } ?? []
        )
    }

    /// The names containers are registered under and the names queries carry are not the
    /// same shape, and this is where they meet. A container is registered under its bare id
    /// ("web"), or, on its first network when a DNS domain is configured, under the qualified
    /// name with a root dot ("web.test."); its aliases are bare. Queries arrive in wire form:
    /// always a trailing dot, and often qualified by a search domain ("web.test." for "web").
    ///
    /// So try the name without the root dot, then as asked, then its first label. First-label
    /// matching is safe because bare registrations are single labels and because every query
    /// that reaches this resolver was routed here for a container domain: by the host's
    /// /etc/resolver file, or by a guest resolver that forwards only single labels and
    /// search-domain names.
    private func entry(for question: Question, in scope: HostTableScope) async throws -> HostTableEntry? {
        let name = question.name.hasSuffix(".") ? String(question.name.dropLast()) : question.name
        var spellings = [name]
        if question.name != name {
            spellings.append(question.name)
        }
        if let firstLabel = name.split(separator: ".").first.map(String.init), firstLabel != name {
            spellings.append(firstLabel)
        }
        for spelling in spellings {
            if let entry = try await table.entry(named: spelling, in: scope) {
                return entry
            }
        }
        return nil
    }
}
