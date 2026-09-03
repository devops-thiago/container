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

/// The provenance of a durably committed kernel installation.
public struct KernelInstallation: Sendable, Codable, Equatable {
    /// The basename committed to the managed kernel directory.
    public let name: String

    /// The bare lowercase SHA-256 digest of the committed kernel binary.
    public let sha256: String

    public init(name: String, sha256: String) {
        self.name = name
        self.sha256 = sha256
    }
}
