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

#if os(macOS)
import ContainerXPC
import ContainerizationError
import Foundation

/// A registry credential that travels with one request: a pull, a push or a login check. The
/// images service uses it for that request only. It never keeps it and never logs it.
///
/// Printing one shows no part of it, so a stray interpolation cannot leak it.
public struct RegistryCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let username: String
    /// A password, or an identity token in its place.
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "RegistryCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What a login check found: the registry took the credential, or refused it with this HTTP
/// status. Any other failure (the registry cannot be reached, it timed out) is an error.
public enum RegistryLoginCheck: Sendable, Equatable {
    case accepted
    case rejected(status: Int)
}

extension XPCMessage {
    /// Carries `credential` with this request, or nothing for nil.
    public func set(credential: RegistryCredential?) throws {
        guard let credential else { return }
        set(key: .registryCredential, value: try JSONEncoder().encode(credential))
    }

    /// The credential this request carries, if any. One that does not decode is refused rather
    /// than ignored, so a request never falls back to another login by mistake.
    public func registryCredential() throws -> RegistryCredential? {
        guard let data = dataNoCopy(key: .registryCredential) else { return nil }
        do {
            return try JSONDecoder().decode(RegistryCredential.self, from: data)
        } catch {
            // The decoder's error can quote the input: say nothing of it.
            throw ContainerizationError(.invalidArgument, message: "the registry credential sent with the request could not be read")
        }
    }
}

#endif
