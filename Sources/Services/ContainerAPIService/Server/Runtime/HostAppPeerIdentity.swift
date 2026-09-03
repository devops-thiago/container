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

import ContainerVersion
import ContainerXPC
import Foundation
import Security
import XPC

/// Authenticates the host app at the routes that establish or extend the grant broker.
///
/// The API listener is deliberately shared with the CLI and spawned helpers, so a global XPC
/// signing requirement would break those callers. Grant publication instead verifies the code
/// associated with the received message's audit token. Matching EUID, a payload PID, and a
/// caller-chosen endpoint token are not identities: the peer must be validly signed as the
/// configured host bundle by the same team that signed this API service.
enum HostAppPeerIdentity {
    struct SigningIdentity: Equatable, Sendable {
        let identifier: String
        let teamIdentifier: String
    }

    static func isAuthorized(_ message: XPCMessage) -> Bool {
        guard
            let expectedIdentifier = ServiceIdentity.hostAppBundleIdentifier,
            !expectedIdentifier.isEmpty,
            let expected = selfIdentity(),
            let peer = messageIdentity(message)
        else { return false }
        return matches(
            peer,
            expectedIdentifier: expectedIdentifier,
            expectedTeamIdentifier: expected.teamIdentifier)
    }

    /// Pure policy seam for deterministic hostile-publisher tests.
    static func matches(
        _ peer: SigningIdentity,
        expectedIdentifier: String,
        expectedTeamIdentifier: String
    ) -> Bool {
        !expectedIdentifier.isEmpty
            && !expectedTeamIdentifier.isEmpty
            && peer.identifier == expectedIdentifier
            && peer.teamIdentifier == expectedTeamIdentifier
    }

    private static func selfIdentity() -> SigningIdentity? {
        var code: SecCode?
        guard
            SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return nil }
        return signingIdentity(code)
    }

    private static func messageIdentity(_ message: XPCMessage) -> SigningIdentity? {
        var code: SecCode?
        guard
            SecCodeCreateWithXPCMessage(message.underlying, SecCSFlags(), &code) == errSecSuccess,
            let code,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { return nil }
        return signingIdentity(code)
    }

    private static func signingIdentity(_ code: SecCode) -> SigningIdentity? {
        var information: CFDictionary?
        // The Security C API accepts a dynamic SecCode here, although the Swift importer types
        // this parameter as SecStaticCode. Both are CF code references.
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [CFString: Any],
            let identifier = values[kSecCodeInfoIdentifier] as? String,
            let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
            !identifier.isEmpty,
            !teamIdentifier.isEmpty
        else { return nil }
        return SigningIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
    }
}
