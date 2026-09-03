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

import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// Records the endpoints that spawned plugin instances announce.
///
/// Under sandboxed embedding a posix_spawned helper cannot own a launchd mach
/// name (SMAppService plists are static, and a sandboxed parent can only spawn
/// inherit children — spike S2c). Each instance instead publishes the endpoint
/// of its anonymous listener here, keyed by the mach name it would otherwise
/// have owned, and `InstanceEndpoints` hands that endpoint to whichever client
/// dials the name.
public struct InstanceAttachHarness: Sendable {
    private let log: Logger
    private let verifyHostApp: @Sendable (XPCMessage) -> Bool
    private let helperOwnerToken: String

    public init(log: Logger) {
        self.log = log
        self.verifyHostApp = HostAppPeerIdentity.isAuthorized
        self.helperOwnerToken = InstanceAttach.ownerToken
    }

    init(
        log: Logger,
        verifyHostApp: @escaping @Sendable (XPCMessage) -> Bool,
        helperOwnerToken: String = InstanceAttach.ownerToken
    ) {
        self.log = log
        self.verifyHostApp = verifyHostApp
        self.helperOwnerToken = helperOwnerToken
    }

    public func attach(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        let label = message.string(key: "id") ?? ""
        let isGrantPublisher = label == HostDirectoryGrants.vendorLabel
        let authorized = Self.publisherAuthorized(
            label: label,
            token: message.string(key: InstanceAttach.tokenKey),
            hostAppVerified: isGrantPublisher && verifyHostApp(message),
            helperOwnerToken: helperOwnerToken)
        try Self.record(
            message,
            peerPID: session.peerPID,
            authorizedPublisher: authorized,
            log: log)
        return message.reply()
    }

    /// A fixed grant label belongs only to the signed app. Every other brokered label belongs
    /// only to a helper carrying the API server's inherited boot token, which prevents a random
    /// same-EUID process from winning a predictable helper-label race before the real child.
    static func publisherAuthorized(
        label: String,
        token: String?,
        hostAppVerified: Bool,
        helperOwnerToken: String
    ) -> Bool {
        if label == HostDirectoryGrants.vendorLabel { return hostAppVerified }
        guard
            let token,
            !token.isEmpty,
            !helperOwnerToken.isEmpty,
            token.utf8.count == helperOwnerToken.utf8.count
        else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(token.utf8, helperOwnerToken.utf8) { difference |= a ^ b }
        return difference == 0
    }

    /// Parse and record an attach while taking process identity only from the accepted XPC peer.
    /// The legacy `pid` payload may still be sent by older clients, but it is deliberately never
    /// read: a sender cannot nominate a long-lived process to make a squatted label sticky.
    static func record(
        _ message: XPCMessage,
        peerPID: pid_t,
        authorizedPublisher: Bool,
        log: Logger
    ) throws {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "instance attach: missing id")
        }
        guard let endpoint = message.endpoint(key: "endpoint") else {
            throw ContainerizationError(
                .invalidArgument, message: "instance attach: missing endpoint")
        }
        try record(
            label: id,
            endpoint: endpoint,
            token: message.string(key: InstanceAttach.tokenKey),
            peerPID: peerPID,
            authorizedPublisher: authorizedPublisher,
            log: log)
    }

    /// The attach decision, apart from its XPC envelope.
    ///
    /// Spawned helpers retain their inherited owner-token flow, and presenting that exact boot
    /// token authenticates even their first publication. The fixed grants label is stronger:
    /// its first publication, heartbeat replacement, and successor replacement all require the
    /// audit-token-backed SiliconShip signing identity before token ownership is considered.
    static func record(
        label: String,
        endpoint: xpc_endpoint_t,
        token: String?,
        peerPID: pid_t,
        authorizedPublisher: Bool = true,
        log: Logger
    ) throws {
        guard peerPID > 0 else {
            throw ContainerizationError(.invalidState, message: "instance attach: missing XPC peer identity")
        }
        guard authorizedPublisher else {
            log.error(
                "instance attach refused: publisher identity is not authorized",
                metadata: ["id": "\(label)"])
            throw ContainerizationError(.invalidState, message: "instance attach: unauthorized publisher")
        }
        guard let token, !token.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "instance attach: missing owner token")
        }
        do {
            try InstanceEndpoints.attach(label: label, endpoint: endpoint, owner: token, pid: peerPID)
        } catch is InstanceEndpoints.OwnedByAnother {
            log.error(
                "instance attach refused: label owned by another publisher",
                metadata: ["id": "\(label)", "pid": "\(peerPID)"])
            throw ContainerizationError(
                .invalidState, message: "instance attach: \(label) is published by another process")
        }
        log.info("instance attached", metadata: ["id": "\(label)", "pid": "\(peerPID)"])
    }

    /// Hand a recorded endpoint back to a helper that needs to dial another
    /// instance (see InstanceAttach.resolve).
    public func resolve(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "instance resolve: missing id")
        }
        let reply = message.reply()
        if let endpoint = try Self.lookup(
            label: id, token: message.string(key: InstanceAttach.tokenKey), log: log)
        {
            reply.set(key: "endpoint", value: endpoint)
        }
        return reply
    }

    /// The resolve decision, apart from its XPC envelope. Nil when nothing is published
    /// under `label`; a throw when the caller may not have what is.
    ///
    /// An endpoint is handed out only to a caller presenting the token it was published with.
    /// Helpers the apiserver spawned share its token and so find each other; the authenticated
    /// host app's endpoint, published with a token only it holds, is never handed to an unrelated
    /// same-user process — the broker dials it itself and echoes that token at the second boundary.
    static func lookup(label: String, token: String?, log: Logger) throws -> xpc_endpoint_t? {
        guard let token, !token.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "instance resolve: missing owner token")
        }
        guard let endpoint = InstanceEndpoints.endpoint(label: label) else {
            log.error("instance resolve: no endpoint recorded", metadata: ["id": "\(label)"])
            return nil
        }
        guard InstanceEndpoints.owner(label: label) == token else {
            log.error("instance resolve refused: caller does not own the label", metadata: ["id": "\(label)"])
            throw ContainerizationError(
                .invalidState, message: "instance resolve: \(label) is not published by the caller")
        }
        return endpoint
    }
}
