//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerAPIService
import ContainerizationExtras
import DNSServer

/// Handler that uses table lookup to resolve hostnames.
struct ContainerDNSHandler: DNSHandler {
    private let networkService: NetworksService
    private let ttl: UInt32

    public init(networkService: NetworksService, ttl: UInt32 = 5) {
        self.networkService = networkService
        self.ttl = ttl
    }

    public func answer(query: Message) async throws -> Message? {
        guard let question = query.questions.first else {
            return nil
        }
        let records: [ResourceRecord]
        switch question.type {
        case ResourceRecordType.host:
            records = try await answerHost(question: question)
        case ResourceRecordType.host6:
            let result = try await answerHost6(question: question)
            if result.records.isEmpty && result.hostnameExists {
                // Return NODATA (noError with empty answers) when hostname exists but has no IPv6.
                // This is required because musl libc has issues when A record exists but AAAA returns NXDOMAIN.
                // musl treats NXDOMAIN on AAAA as "domain doesn't exist" and fails DNS resolution entirely.
                // NODATA correctly indicates "no IPv6 address available, but domain exists".
                return Message(
                    id: query.id,
                    type: .response,
                    returnCode: .noError,
                    questions: query.questions,
                    answers: []
                )
            }
            records = result.records
        default:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
        }

        guard !records.isEmpty else {
            return nil
        }

        return Message(
            id: query.id,
            type: .response,
            returnCode: .noError,
            questions: query.questions,
            answers: records
        )
    }

    /// The names containers are registered under and the names queries carry are not always
    /// the same shape. The network helpers already match a query's own name, with or without
    /// its root dot, against hostnames and aliases. A container registered by its bare id
    /// ("web", when no default domain is configured) is still asked for qualified by a search
    /// domain ("web.test."), so when the name as asked misses, take the first label.
    ///
    /// First-label matching is safe because such registered names are single labels, and
    /// because every query that reaches this resolver was already scoped to a container
    /// domain by the /etc/resolver file that routed it here.
    private func registeredName(for question: Question) async throws -> String? {
        if try await networkService.lookup(hostname: question.name) != nil {
            return question.name
        }
        let name = question.name.hasSuffix(".") ? String(question.name.dropLast()) : question.name
        guard let firstLabel = name.split(separator: ".").first.map(String.init),
            firstLabel != name
        else {
            return nil
        }
        return try await networkService.lookup(hostname: firstLabel) != nil ? firstLabel : nil
    }

    /// One A record per attachment the name resolves to: an alias several containers share
    /// answers with every address that holds it, as Docker's DNS does.
    private func answerHost(question: Question) async throws -> [ResourceRecord] {
        guard let hostname = try await registeredName(for: question) else {
            return []
        }
        return try await networkService.lookupAll(hostname: hostname).map { attachment in
            let ipv4 = attachment.ipv4Address.address.description
            guard let ip = try? IPv4Address(ipv4) else {
                throw DNSResolverError.serverError("failed to parse IP address: \(ipv4)")
            }
            return HostRecord<IPv4Address>(name: question.name, ttl: ttl, ip: ip)
        }
    }

    private func answerHost6(question: Question) async throws -> (records: [ResourceRecord], hostnameExists: Bool) {
        guard let hostname = try await registeredName(for: question) else {
            return ([], false)
        }
        let attachments = try await networkService.lookupAll(hostname: hostname)
        guard !attachments.isEmpty else {
            return ([], false)
        }
        let records: [ResourceRecord] = try attachments.compactMap { attachment in
            guard let ipv6Address = attachment.ipv6Address else {
                return nil
            }
            let ipv6 = ipv6Address.address.description
            guard let ip = try? IPv6Address(ipv6) else {
                throw DNSResolverError.serverError("failed to parse IPv6 address: \(ipv6)")
            }
            return HostRecord<IPv6Address>(name: question.name, ttl: ttl, ip: ip)
        }
        return (records, true)
    }
}
