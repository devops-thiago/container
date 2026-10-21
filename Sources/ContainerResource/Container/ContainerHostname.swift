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

import CryptoKit
import Foundation

/// The name a container answers to on its networks and as its own hostname, when nothing
/// else names one.
///
/// A container's ID is its name, and a name may be longer than the 63 characters a DNS label
/// or a Linux hostname can have: Docker Compose names a container `<project>-<service>-1`,
/// and a project is named after its folder. Docker gives every container the short form of
/// its ID as hostname. Here the ID is the name, so a name that fits stays the hostname, and
/// one that does not is given the short ID Docker clients see for it: the first 12 hex digits
/// of the SHA-256 of the name.
public enum ContainerHostname {
    /// The longest DNS label, and so the longest hostname a container takes.
    public static let maxLabelLength = 63

    /// The length of a Docker short ID.
    public static let shortIDLength = 12

    /// The container's hostname: `id` when each of its dot-separated labels fits a DNS label,
    /// its short ID otherwise.
    public static func `default`(for id: String) -> String {
        fits(id) ? id : shortID(for: id)
    }

    /// Whether `name` is used as the hostname as it is: no label between its dots is longer
    /// than 63 characters, which is every name the engine took before longer ones.
    public static func fits(_ name: String) -> Bool {
        name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { $0.utf8.count <= maxLabelLength }
    }

    /// The full Docker ID of a container whose engine ID is `id`: the SHA-256 of it, in hex.
    public static func dockerID(for id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The short form of ``dockerID(for:)``.
    public static func shortID(for id: String) -> String {
        String(dockerID(for: id).prefix(shortIDLength))
    }
}
