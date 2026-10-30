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
import DNSServer

/// Validates the DNS names that the network attachments of a new container claim.
///
/// A container claims the hostname of each attachment, which must be unique across all containers,
/// whether they are running or stopped. Its exact aliases may be shared, as Docker allows. A subtree alias such as
/// `.example.test` must be rooted at a name that the same attachment owns, so a container cannot claim
/// the part of the namespace below another container's name.
enum AttachmentNameValidator {
    /// The most aliases that a single attachment may declare.
    static let maximumAliasesPerAttachment = AliasPolicy.maximumAliasesPerAttachment

    /// The fewest labels that an exact alias, or the base of a subtree alias, may have.
    static let minimumAliasLabels = AliasPolicy.minimumLabels

    /// Validates the attachments of a new container against the attachments of all existing containers.
    ///
    /// Names are compared case-insensitively and without a trailing dot.
    ///
    /// - Parameters:
    ///   - networks: The attachments of the container being created.
    ///   - existing: The attachments of every existing container.
    /// - Throws: `ContainerizationError` with code `.exists` if a hostname or alias is already claimed,
    ///   and with code `.invalidArgument` if an alias is malformed or breaks a rule.
    static func validate(
        networks: [AttachmentConfiguration], existing: [AttachmentConfiguration], tolerant: Bool = false
    ) throws {
        try NamespaceInventory(containers: ["": existing]).validate(networks: networks, excluding: nil, tolerant: tolerant)
    }

    /// A shared index for restoring all saved attachments. Owner IDs let each resource
    /// ignore its own claims without rebuilding the other containers' names each time.
    struct NamespaceInventory: Sendable {
        private var claimed: [String: Set<String>] = [:]
        private var exactNames: [DNSName: Set<String>] = [:]
        private var subtrees: [DNSName: Set<String>] = [:]
        private var privateSubtrees: [DNSName: Set<String>] = [:]

        init(containers: [String: [AttachmentConfiguration]]) throws {
            for (owner, attachments) in containers {
                for attachment in attachments {
                    claimed[AttachmentOptions.canonicalHostname(attachment.options.hostname), default: []].insert(owner)
                    let hostname = try? DNSName(AttachmentOptions.canonicalHostname(attachment.options.hostname))
                    if let hostname { exactNames[hostname, default: []].insert(owner) }
                    let rules = try AliasPolicy.validate(
                        aliases: attachment.options.aliases, hostname: hostname, network: attachment.network, tolerant: true)
                    for rule in rules {
                        switch rule {
                        case .exact(let name): exactNames[name, default: []].insert(owner)
                        case .subtree(let base):
                            subtrees[base, default: []].insert(owner)
                            if base != hostname { privateSubtrees[base, default: []].insert(owner) }
                        }
                    }
                }
            }
        }

        func validate(networks: [AttachmentConfiguration], excluding owner: String?, tolerant: Bool) throws {
            func foreign(_ owners: Set<String>?) -> Bool {
                guard let owners, !owners.isEmpty else { return false }
                return owners.count > 1 || owners.first != owner
            }

            var conflictingHostnames = [String]()
            for attachment in networks where foreign(claimed[AttachmentOptions.canonicalHostname(attachment.options.hostname)]) {
                conflictingHostnames.append(attachment.options.hostname)
            }
            guard conflictingHostnames.isEmpty else {
                throw ContainerizationError(.exists, message: "hostname(s) already exist: \(conflictingHostnames)")
            }

            for attachment in networks {
                // The rules that depend only on this attachment are shared with the network helper.
                let hostname = try? DNSName(AttachmentOptions.canonicalHostname(attachment.options.hostname))
                let rules: [DNSMatchRule]
                do {
                    rules = try AliasPolicy.validate(
                        aliases: attachment.options.aliases, hostname: hostname, network: attachment.network, tolerant: tolerant)
                } catch let violation as AliasPolicy.Violation {
                    throw ContainerizationError(.invalidArgument, message: violation.description)
                }
                do {
                    try AliasPolicy.validateNamespace(
                        hostname: hostname, aliases: rules,
                        foreignExactName: { foreign(exactNames[$0]) },
                        foreignSubtree: { foreign(subtrees[$0]) },
                        foreignPrivateSubtree: { foreign(privateSubtrees[$0]) })
                } catch let violation as AliasPolicy.Violation {
                    throw ContainerizationError(.exists, message: violation.description)
                }
            }
        }

    }

    /// Validates the attachments of a container that was read back from storage.
    ///
    /// The stored configuration is not trusted to be what `validate` accepted when the container was
    /// created, since the file can be damaged or edited. Check ownership against the other stored
    /// containers too, before reservations or startup; an unsafe claim leaves its data intact.
    ///
    /// - Throws: `ContainerizationError` with code `.invalidState` if the stored names break a rule.
    static func validateStored(id: String, networks: [AttachmentConfiguration], existing: [AttachmentConfiguration]) throws {
        let inventory = try NamespaceInventory(containers: ["": existing])
        try validateStored(id: id, networks: networks, inventory: inventory, excluding: nil)
    }

    static func validateStored(
        id: String, networks: [AttachmentConfiguration], inventory: NamespaceInventory, excluding owner: String?
    ) throws {
        do {
            // Malformed legacy aliases are still omitted from DNS. Conflicting namespace
            // ownership is refused before startup, without rewriting or deleting the bundle.
            try inventory.validate(networks: networks, excluding: owner, tolerant: true)
        } catch let error as ContainerizationError {
            throw ContainerizationError(
                .invalidState,
                message: "the stored configuration of container \(id) has invalid network names: \(error)"
            )
        }
    }

}
