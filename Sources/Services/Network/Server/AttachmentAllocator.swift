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
import DNSServer

actor AttachmentAllocator {
    /// The kind of name that matched a query.
    enum MatchKind: Sendable, Equatable {
        /// The hostname of an attachment.
        case hostname
        /// An exact alias of an attachment.
        case alias
        /// A subtree alias of an attachment, with the number of labels in its base.
        case subtree(baseLabelCount: Int)
    }

    /// The attachment that a name resolves to.
    struct Match: Sendable, Equatable {
        /// The allocator index of the attachment.
        let index: UInt32
        /// The canonical hostname of the attachment, which is not necessarily the name that matched.
        let hostname: String
        let kind: MatchKind
    }

    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: UInt32] = [:]
    // Exact aliases, as the canonical alias mapped to the canonical hostnames that hold it, in the
    // order they registered it. As Docker allows, several hosts may share an exact alias, and an
    // alias may be another host's hostname.
    private var exactAliases: [String: [String]] = [:]
    // Subtree aliases, as the base name mapped to the canonical hostname that owns it.
    private var subtreeAliases: [DNSName: String] = [:]
    // The aliases registered for each canonical hostname, so that they can be removed with it.
    private var aliasesByHostname: [String: [DNSMatchRule]] = [:]
    /// How many holders each hostname has: the engine, from a container's create to its
    /// delete, and the container's runtime while it runs. The address goes back to the pool
    /// when the last one lets go, so a stopped container keeps the address it had.
    private var holders: [String: Int] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Allocate a network address for a host, or hand another holder the one it has, and register
    /// aliases that resolve to it.
    ///
    /// An exact alias may be shared: as Docker allows, every host that declares it holds it, and
    /// it may also be another host's hostname. The allocation fails without changing any state if a
    /// subtree alias is already held by another host on this network.
    ///
    /// - Throws: `ContainerizationError` with code `.exists` if a subtree alias is already in use.
    @discardableResult
    func allocate(hostname: String, aliases: [DNSMatchRule] = []) async throws -> UInt32 {
        let hostname = AttachmentOptions.canonicalHostname(hostname)

        var newAliases = [DNSMatchRule]()
        for rule in aliases where !newAliases.contains(rule) {
            switch rule {
            case .exact:
                let name = rule.description
                if name == hostname || exactAliases[name]?.contains(hostname) == true {
                    continue
                }
            case .subtree(let base):
                if let owner = subtreeAliases[base] {
                    if owner == hostname {
                        continue
                    }
                    throw ContainerizationError(.exists, message: "alias \(rule) is already an alias of \(owner)")
                }
            }
            newAliases.append(rule)
        }

        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists.
        // Each call is another holder: the engine, from a container's create to its delete, and the
        // container's runtime while it runs.
        let index: UInt32
        if let existing = hostnames[hostname] {
            index = existing
            holders[hostname, default: 0] += 1
        } else {
            index = try allocator.allocate()
            hostnames[hostname] = index
            holders[hostname] = 1
        }

        for rule in newAliases {
            switch rule {
            case .exact:
                exactAliases[rule.description, default: []].append(hostname)
            case .subtree(let base):
                subtreeAliases[base] = hostname
            }
        }
        aliasesByHostname[hostname, default: []].append(contentsOf: newAliases)

        return index
    }

    /// Let go of a hostname's address. It is freed, and returned, along with the aliases registered
    /// for it, only when no holder is left; nil while another still has it, or when the hostname was
    /// never allocated.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        let hostname = AttachmentOptions.canonicalHostname(hostname)
        guard let index = hostnames[hostname] else {
            return nil
        }
        let remaining = (holders[hostname] ?? 1) - 1
        guard remaining <= 0 else {
            holders[hostname] = remaining
            return nil
        }
        holders.removeValue(forKey: hostname)
        hostnames.removeValue(forKey: hostname)

        for rule in aliasesByHostname.removeValue(forKey: hostname) ?? [] {
            switch rule {
            case .exact:
                let name = rule.description
                exactAliases[name]?.removeAll { $0 == hostname }
                if exactAliases[name]?.isEmpty == true {
                    exactAliases.removeValue(forKey: name)
                }
            case .subtree(let base):
                subtreeAliases.removeValue(forKey: base)
            }
        }

        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname. Aliases are not considered.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[AttachmentOptions.canonicalHostname(hostname)]
    }

    /// Find the attachment that a name resolves to first.
    ///
    /// A hostname wins over an exact alias, and an exact alias wins over a subtree alias. Among the
    /// hosts sharing an exact alias the first to register it wins. Among subtree aliases the one with
    /// the longest base wins.
    func match(name: String) async throws -> Match? {
        try await matches(name: name).first
    }

    /// Every attachment that a name resolves to, as Docker's DNS answers a shared alias with every
    /// address that holds it: the host with that hostname first, then each host holding the name as
    /// an exact alias, in registration order. Only when nothing has the exact name does the subtree
    /// alias with the longest base answer, alone.
    func matches(name: String) async throws -> [Match] {
        let name = AttachmentOptions.canonicalHostname(name)
        var result = [Match]()
        if let index = hostnames[name] {
            result.append(Match(index: index, hostname: name, kind: .hostname))
        }
        for owner in exactAliases[name] ?? [] where owner != name {
            if let index = hostnames[owner], !result.contains(where: { $0.index == index }) {
                result.append(Match(index: index, hostname: owner, kind: .alias))
            }
        }
        guard result.isEmpty else {
            return result
        }
        guard let dnsName = try? DNSName(name) else {
            return []
        }
        for base in DNSMatchRule.subtreeBases(of: dnsName) {
            if let owner = subtreeAliases[base], let index = hostnames[owner] {
                return [Match(index: index, hostname: owner, kind: .subtree(baseLabelCount: base.labels.count))]
            }
        }
        return []
    }

    /// Every current allocation, so a joining container can learn its peers' names.
    func allocations() async -> [String: UInt32] {
        hostnames
    }
}
