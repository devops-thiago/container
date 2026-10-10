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

import ContainerAPIService
import ContainerResource
import ContainerizationExtras
import DNSServer

/// What the container-name table reads from the networks. `NetworksService` in the engine;
/// a fixed table in tests.
protocol ContainerNetworkDirectory: Sendable {
    /// The running network whose subnet holds `address`, if any.
    func network(containing address: IPv4Address) async -> String?
    /// The attachment `name` resolves to on `network`, or on any network when nil.
    func lookup(name: String, network: String?) async throws -> Attachment?
}

extension NetworksService: ContainerNetworkDirectory {}

/// The container names the engine's resolver answers, read live from the networks.
///
/// The resolver listens beyond loopback so a guest can reach it through its network's
/// gateway, which also puts it in front of whatever else can reach the Mac. Who asks
/// decides what they see:
/// - the Mac itself (loopback) — every network, as before: the host's /etc/resolver file
///   routes container domains here on behalf of the Mac and of guests whose queries the
///   host resolver forwards;
/// - a container (a sender inside a running network's subnet) — only the containers on
///   that network, as Docker answers only for networks the asker shares;
/// - anyone else — refused.
struct ContainerNameTable: ScopedHostTable {
    private let networks: any ContainerNetworkDirectory

    init(networks: any ContainerNetworkDirectory) {
        self.networks = networks
    }

    /// The handler chain the engine serves container names with: malformed queries are
    /// rejected, registered names answered, strangers refused, and everything else NXDOMAIN.
    static func resolver(networks: any ContainerNetworkDirectory) -> any DNSHandler {
        StandardQueryValidator(
            handler: CompositeResolver(handlers: [
                ScopedHostTableResolver(table: ContainerNameTable(networks: networks)),
                NxDomainResolver(),
            ]))
    }

    func scope(for source: DNSQuerySource) async throws -> HostTableScope? {
        guard case .ipv4(let address) = source else {
            return nil
        }
        if address.isLoopback {
            return .all
        }
        return await networks.network(containing: address).map { .view($0) }
    }

    func entry(named name: String, in scope: HostTableScope) async throws -> HostTableEntry? {
        let network: String? =
            switch scope {
            case .all: nil
            case .view(let network): network
            }
        guard let attachment = try await networks.lookup(name: name, network: network) else {
            return nil
        }
        return HostTableEntry(ipv4: attachment.ipv4Address.address, ipv6: attachment.ipv6Address?.address)
    }
}
