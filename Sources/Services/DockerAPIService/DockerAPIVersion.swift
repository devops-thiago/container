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

/// A Docker Engine API version, such as `1.48`.
///
/// Clients put the version they speak in the path (`/v1.48/containers/json`); a path without one
/// is served at the current version, as dockerd does.
public struct DockerAPIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `1.48`. Nil for anything else.
    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0 else {
            return nil
        }
        self.init(major: major, minor: minor)
    }

    /// The version this service implements, and reports in `/version` and every response's
    /// `Api-Version` header.
    public static let current = DockerAPIVersion(major: 1, minor: 48)
    /// The oldest version a client may ask for.
    public static let minimum = DockerAPIVersion(major: 1, minor: 44)
    /// The Docker Engine release that introduced `current`, which `/version` (`Version`) and
    /// `/info` (`ServerVersion`) report as the server's version: clients compare it with
    /// Docker's own releases, not with this engine's. Testcontainers refuses a server below 1.6.0 and the Dev Containers CLI turns
    /// features on from 23.0.0, so this engine's own version (1.x) would read as an ancient
    /// dockerd. moby `api/swagger.yaml` is at 1.47 in v27.5.1 and 1.48 in v28.0.0.
    public static let dockerRelease = "28.0.0"

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
