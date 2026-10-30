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
        // Only hostnames are exclusive. As Docker allows, an exact alias may be shared by several
        // containers on a network, may be declared on several networks, and may be another
        // container's hostname; a shared alias resolves to every container that holds it.
        var claimed = Set<String>()
        for attachment in existing {
            claimed.insert(AttachmentOptions.canonicalHostname(attachment.options.hostname))
        }

        var conflictingHostnames = [String]()
        for attachment in networks where claimed.contains(AttachmentOptions.canonicalHostname(attachment.options.hostname)) {
            conflictingHostnames.append(attachment.options.hostname)
        }
        guard conflictingHostnames.isEmpty else {
            throw ContainerizationError(.exists, message: "hostname(s) already exist: \(conflictingHostnames)")
        }

        for attachment in networks where !attachment.options.aliases.isEmpty {
            // The rules that depend only on this attachment are shared with the network helper.
            do {
                let hostname = try? DNSName(AttachmentOptions.canonicalHostname(attachment.options.hostname))
                _ = try AliasPolicy.validate(
                    aliases: attachment.options.aliases, hostname: hostname, network: attachment.network, tolerant: tolerant)
            } catch let violation as AliasPolicy.Violation {
                throw ContainerizationError(.invalidArgument, message: violation.description)
            }
        }
    }

    /// Validates the attachments of a container that was read back from storage.
    ///
    /// The stored configuration is not trusted to be what `validate` accepted when the container was
    /// created, since the file can be damaged or edited. This checks every rule that does not depend on
    /// other containers, so a stored container with bad names fails to start with an explanation.
    ///
    /// - Throws: `ContainerizationError` with code `.invalidState` if the stored names break a rule.
    static func validateStored(id: String, networks: [AttachmentConfiguration]) throws {
        do {
            // Tolerant: a container an earlier engine stored, with names it accepted then, must
            // still start; a name that breaks today's rules is only left out of DNS.
            try validate(networks: networks, existing: [], tolerant: true)
        } catch let error as ContainerizationError {
            throw ContainerizationError(
                .invalidState,
                message: "the stored configuration of container \(id) has invalid network names: \(error)"
            )
        }
    }

    /// The normalized form of an alias that was stored with an existing container.
    private static func canonicalAlias(_ alias: String) -> String {
        guard let rule = try? DNSMatchRule(alias) else {
            return AttachmentOptions.canonicalHostname(alias)
        }
        return rule.description
    }
}
