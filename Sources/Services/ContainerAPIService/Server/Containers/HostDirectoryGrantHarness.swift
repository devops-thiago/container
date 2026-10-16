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

    /// A client borrowing a folder for its own process (`container build` reads its context
    /// itself). Gated like every workload route by the owner watchdog, and no further: the
    /// pool lends only what the user has granted, and asks the user for anything else.
    ///
    /// The panel, if one is needed, names the borrower: the process on the other end of the
    /// connection, which for a build is `container`.
    public func lend(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        try await lend(message, peerPID: session.peerPID)
    }

    func lend(_ message: XPCMessage, peerPID: pid_t) async throws -> XPCMessage {
        guard let path = message.string(key: .hostDirectoryPath), !path.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "a host directory lend names no path")
        }
        let requester = ContainersHarness.requester(of: message, peerPID: peerPID)
        let (bookmark, outcome) = await HostDirectoryGrants.shared.lend(path, requester: requester)
        let reply = message.reply()
        reply.set(key: .hostDirectoryOutcome, value: Self.wire(outcome).rawValue)
        if let bookmark {
            reply.set(key: .hostDirectoryBookmarks, value: bookmark)
        }
        log.info("host directory lend", metadata: ["path": "\(path)", "outcome": "\(Self.wire(outcome).rawValue)"])
        return reply
    }

    /// The embedder taking a folder back. Authorized exactly like `publish`, because only the app
    /// that granted the folders may take them away: anyone else revoking would be a same-user
    /// process quietly breaking the user's mounts. An unknown folder is not an error, so a retry
    /// after a lost reply succeeds; anything else that goes wrong is thrown to the caller.
    public func revoke(_ message: XPCMessage) async throws -> XPCMessage {
        let owner = InstanceEndpoints.owner(label: HostDirectoryGrants.vendorLabel)
        guard Self.authorized(message, peerIsHostApp: verifyHostApp(message), ownerToken: owner)
        else {
            log.error("refused a host directory revoke from an unauthorized caller")
            throw ContainerizationError(.invalidState, message: "unauthorized host directory grant revoke")
        }
        let outcome = try await Self.revoke(path: message.string(key: .hostDirectoryPath), in: HostDirectoryGrants.shared)
        let reply = message.reply()
        reply.set(key: .hostDirectoryOutcome, value: outcome.rawValue)
        return reply
    }

    /// The revoke after authorization, against a given pool so it can be tested, in its wire form.
    static func revoke(path: String?, in pool: HostDirectoryGrants) async throws -> HostDirectoryRevokeOutcome {
        guard let path, !path.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "a host directory revoke names no path")
        }
        switch await pool.revoke(path) {
        case .revoked: return .revoked
        case .notGranted: return .notGranted
        }
    }

    static func wire(_ outcome: HostDirectoryGrants.GrantOutcome) -> HostDirectoryLendOutcome {
        switch outcome {
        case .granted: return .granted
        case .declined: return .declined
        case .noEmbedder: return .noEmbedder
        case .timedOut: return .timedOut
        }
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
