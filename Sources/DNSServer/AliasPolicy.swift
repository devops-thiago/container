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

/// The rules that the aliases of one network attachment must follow.
///
/// The API server checks these rules when a container is created, again when a stored container is
/// started, and the network helper checks them again when it registers the aliases. Each of those
/// reads the aliases from somewhere that can be wrong or malicious, so none of them takes the aliases
/// on faith. Rules that involve other containers, such as a name that is already taken, are not here.
public enum AliasPolicy {
    /// The most aliases that a single attachment may declare.
    public static let maximumAliasesPerAttachment = 32

    /// The fewest labels that the base of a subtree alias may have.
    ///
    /// A subtree alias with a one-label base would capture a whole top-level domain. An exact alias
    /// may have one label, a Docker-style service name: peers' hosts files list it.
    public static let minimumLabels = 2

    /// A rule that an alias breaks. The description says which alias and why.
    public struct Violation: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    /// Parses the aliases of one attachment and checks that they follow the rules.
    ///
    /// - There are at most `maximumAliasesPerAttachment` of them, and each one is a valid rule.
    /// - No alias is listed twice, and an exact alias is not the hostname of the attachment.
    /// - A subtree alias has a base with at least `minimumLabels` labels, and the base is the hostname
    ///   of the attachment or one of its exact aliases, so an attachment cannot claim the names below
    ///   a name that it does not own.
    ///
    /// - Parameters:
    ///   - aliases: The aliases in their string form.
    ///   - hostname: The hostname of the attachment, or nil if it is not a valid DNS name.
    ///   - network: The name of the network, which is used in error descriptions.
    /// - Returns: The aliases as rules, in the order they were given.
    /// - Throws: `Violation` for the first rule that is broken.
    public static func validate(aliases: [String], hostname: DNSName?, network: String) throws -> [DNSMatchRule] {
        guard aliases.count <= Self.maximumAliasesPerAttachment else {
            throw Violation("network \(network) has \(aliases.count) aliases, but at most \(Self.maximumAliasesPerAttachment) are allowed")
        }

        var rules = [(alias: String, rule: DNSMatchRule)]()
        for alias in aliases {
            do {
                rules.append((alias, try DNSMatchRule(alias)))
            } catch {
                throw Violation("invalid alias \"\(alias)\" for network \(network): \(error)")
            }
        }

        // The names this attachment owns, which are the roots a subtree alias may use.
        var owned = Set<DNSName>()
        if let hostname {
            owned.insert(hostname)
        }
        for case (_, .exact(let name)) in rules {
            owned.insert(name)
        }

        var seen = Set<DNSMatchRule>()
        for (alias, rule) in rules {
            guard seen.insert(rule).inserted else {
                throw Violation("alias \"\(alias)\" is listed more than once for network \(network)")
            }
            switch rule {
            case .exact(let name):
                // A single-label exact alias is allowed, as Docker allows it: the system
                // resolver never routes it here, but peers' hosts files list it, and the
                // container DNS server answers it when a search domain is appended.
                guard name != hostname else {
                    throw Violation("alias \"\(alias)\" is already a hostname of the container")
                }
            case .subtree(let base):
                guard base.labels.count >= Self.minimumLabels else {
                    throw Violation(
                        "alias \"\(alias)\" must have at least \(Self.minimumLabels) labels after the leading dot. Configure a default DNS domain to have the domain added to a name that has none"
                    )
                }
                guard owned.contains(base) else {
                    throw Violation(
                        "alias \"\(alias)\" must be below the hostname or an exact alias of network \(network), but \"\(base.pqdn)\" is neither"
                    )
                }
            }
        }
        return rules.map { $0.rule }
    }
}
