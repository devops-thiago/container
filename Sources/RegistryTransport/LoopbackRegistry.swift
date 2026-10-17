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

/// Whether a registry is on this machine's loopback interface: the only registries a credential
/// may be sent to over plain HTTP.
///
/// Docker treats `127.0.0.0/8` and `::1/128` as insecure registries by default and talks plain
/// HTTP to them. This matches the name `localhost` and IP literals only. Docker also resolves
/// other names and treats one as insecure when every address it resolves to is loopback; that
/// is not done here, so a DNS answer never decides where a credential goes.
public enum LoopbackRegistry {
    /// The host of a registry authority (`host`, `host:port`, `[v6]` or `[v6]:port`), without
    /// its port or brackets.
    public static func host(of authority: String) -> String {
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return authority }
            return String(authority[authority.index(after: authority.startIndex)..<end])
        }
        // More than one colon and no brackets: a bare IPv6 literal, which has no port.
        if authority.filter({ $0 == ":" }).count > 1 {
            return authority
        }
        return authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? authority
    }

    /// Whether `authority` names a registry on loopback: `localhost`, an IPv4 address in
    /// `127.0.0.0/8`, or `::1` (also as the IPv4-mapped form of a `127.0.0.0/8` address), with
    /// or without a port.
    public static func isLoopback(_ authority: String) -> Bool {
        // An authority is not a URL. Reject syntax that URL parsing could interpret as
        // user information, a path, or an escaped delimiter before choosing plain HTTP.
        guard !authority.contains(where: { #"/\@?#%"#.contains($0) || $0.isWhitespace || $0.isNewline }) else { return false }
        let host = host(of: authority)
        if host.lowercased() == "localhost" {
            return true
        }
        if let address = try? IPv4Address(host) {
            return address.isLoopback
        }
        if let address = try? IPv6Address(host), address.zone == nil {
            if address.isLoopback {
                return true
            }
            // ::ffff:127.x.y.z, which Docker unmaps before it matches 127.0.0.0/8.
            if address.value >> 32 == 0xffff {
                return IPv4Address(UInt32(truncatingIfNeeded: address.value)).isLoopback
            }
        }
        return false
    }
}
