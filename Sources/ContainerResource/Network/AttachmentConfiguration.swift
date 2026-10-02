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

/// Configuration information for attaching a container network interface to a network.
public struct AttachmentConfiguration: Codable, Sendable {
    /// The network ID associated with the attachment.
    public let network: String

    /// The option information for the attachment
    public let options: AttachmentOptions

    public init(network: String, options: AttachmentOptions) {
        self.network = network
        self.options = options
    }
}

// Option information for a network attachment.
public struct AttachmentOptions: Codable, Sendable {
    /// The hostname associated with the attachment.
    public let hostname: String

    /// The MAC address associated with the attachment (optional).
    public let macAddress: MACAddress?

    /// The MTU for the network interface.
    public let mtu: UInt32?

    /// Other names the container answers to on this network, beside its hostname: a
    /// service name, the names a stack's file gives it.
    public let aliases: [String]

    public init(hostname: String, macAddress: MACAddress? = nil, mtu: UInt32? = nil, aliases: [String] = []) {
        self.hostname = hostname
        self.macAddress = macAddress
        self.mtu = mtu
        self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case macAddress
        case mtu
        case aliases
    }

    /// A configuration stored before aliases existed has none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decode(String.self, forKey: .hostname)
        macAddress = try container.decodeIfPresent(MACAddress.self, forKey: .macAddress)
        mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(mtu, forKey: .mtu)
        if !aliases.isEmpty {
            try container.encode(aliases, forKey: .aliases)
        }
    }
}
