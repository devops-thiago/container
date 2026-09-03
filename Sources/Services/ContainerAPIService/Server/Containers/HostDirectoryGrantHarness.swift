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

import ContainerAPIClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// Receives the host app's boot-scoped grant publication.
///
/// A readable bookmark proves that its maker had access, not that its maker was SiliconShip.
/// This route therefore applies the same audit-token-backed signing check as the fixed grants
/// endpoint publication, then binds the update to the token of the currently attached app.
public struct HostDirectoryGrantHarness: Sendable {
    private let log: Logger
    private let verifyHostApp: @Sendable (XPCMessage) -> Bool

    public init(log: Logger) {
        self.log = log
        self.verifyHostApp = HostAppPeerIdentity.isAuthorized
    }

    init(log: Logger, verifyHostApp: @escaping @Sendable (XPCMessage) -> Bool) {
        self.log = log
        self.verifyHostApp = verifyHostApp
    }

    public func publish(_ message: XPCMessage) async throws -> XPCMessage {
        let owner = InstanceEndpoints.owner(label: HostDirectoryGrants.vendorLabel)
        guard Self.authorized(message, peerIsHostApp: verifyHostApp(message), ownerToken: owner)
        else {
            log.error("refused host directory grants from an unauthorized publisher")
            throw ContainerizationError(.invalidState, message: "unauthorized host directory grant publisher")
        }
        guard
            let data = message.dataNoCopy(key: .hostDirectoryBookmarks),
            let bookmarks = try? JSONDecoder().decode([Data].self, from: data)
        else { return message.reply() }

        let kept = await HostDirectoryGrants.shared.publish(bookmarks: bookmarks)
        log.info(
            "embedder published host directory grants",
            metadata: ["sent": "\(bookmarks.count)", "kept": "\(kept)"])
        return message.reply()
    }

    /// The authorization decision without the live Security-framework envelope.
    static func authorized(
        _ message: XPCMessage,
        peerIsHostApp: Bool,
        ownerToken: String?
    ) -> Bool {
        guard
            peerIsHostApp,
            let ownerToken,
            !ownerToken.isEmpty,
            let presented = message.string(key: InstanceAttach.tokenKey),
            !presented.isEmpty,
            presented.utf8.count == ownerToken.utf8.count
        else { return false }

        var difference: UInt8 = 0
        for (a, b) in zip(presented.utf8, ownerToken.utf8) { difference |= a ^ b }
        return difference == 0
    }
}
