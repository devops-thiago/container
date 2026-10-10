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
import NIOCore

/// Who sent a query, as far as a handler needs to know.
public enum DNSQuerySource: Sendable, Hashable {
    /// An IPv4 peer.
    case ipv4(IPv4Address)
    /// A peer with no IPv4 address: a Unix-domain socket, or an IPv6 sender.
    case other

    /// The source of a datagram, read from the address NIO reports for its sender.
    public init(_ address: SocketAddress) {
        if case .v4 = address, let text = address.ipAddress, let ip = try? IPv4Address(text) {
            self = .ipv4(ip)
        } else {
            self = .other
        }
    }
}
