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

    public init(log: Logger) {
        self.log = log
    }

    public func attach(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "instance attach: missing id")
        }
        guard let endpoint = message.endpoint(key: "endpoint") else {
            throw ContainerizationError(
                .invalidArgument, message: "instance attach: missing endpoint")
        }
        let pid = pid_t(message.int64(key: "pid"))
        try Self.record(
            label: id, endpoint: endpoint, token: message.string(key: InstanceAttach.tokenKey), pid: pid, log: log)
        return message.reply()
    }

    /// The attach decision, apart from its XPC envelope.
    ///
    /// The trust decision at this boundary: the XPC connection proves the caller is this
    /// user, nothing more, and every process of the user can reach this route. What binds
    /// a label to its publisher is the token presented here — a label can be re-published
    /// only with the token it was first published with. See InstanceAttach.ownerToken.
    static func record(label: String, endpoint: xpc_endpoint_t, token: String?, pid: pid_t, log: Logger) throws {
        guard let token, !token.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "instance attach: missing owner token")
        }
        do {
            try InstanceEndpoints.attach(label: label, endpoint: endpoint, owner: token)
        } catch is InstanceEndpoints.OwnedByAnother {
            log.error("instance attach refused: label owned by another publisher", metadata: ["id": "\(label)", "pid": "\(pid)"])
            throw ContainerizationError(.invalidState, message: "instance attach: \(label) is published by another process")
        }
        log.info("instance attached", metadata: ["id": "\(label)", "pid": "\(pid)"])
    }

    /// Hand a recorded endpoint back to a helper that needs to dial another
    /// instance (see InstanceAttach.resolve).
    public func resolve(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "instance resolve: missing id")
        }
        let reply = message.reply()
        if let endpoint = try Self.lookup(label: id, token: message.string(key: InstanceAttach.tokenKey), log: log) {
            reply.set(key: "endpoint", value: endpoint)
        }
        return reply
    }

    /// The resolve decision, apart from its XPC envelope. Nil when nothing is published
    /// under `label`; a throw when the caller may not have what is.
    ///
    /// Same decision as attach: an endpoint is handed out only to a caller presenting the
    /// token it was published with. Helpers the apiserver spawned share its token and so
    /// find each other; an embedder's endpoint, published with a token only it holds, is
    /// never handed to anyone — the broker dials it itself.
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
            throw ContainerizationError(.invalidState, message: "instance resolve: \(label) is not published by the caller")
        }
        return endpoint
    }
}
