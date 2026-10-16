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

import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// The Docker Engine API over HTTP/1.1, for a listening socket someone else binds.
///
/// Binding is the agent's job: where the socket lives, its permissions and who may connect are
/// decided there. This is what each accepted connection runs.
public struct DockerAPIServer: Sendable {
    public let router: DockerRouter
    public let limits: DockerHTTPLimits
    let log: Logger

    public init(router: DockerRouter, limits: DockerHTTPLimits = .init(), log: Logger = Logger(label: "DockerAPIService")) {
        self.router = router
        self.limits = limits
        self.log = log
    }

    /// Child channel options every accepted connection needs: the CLI half-closes a hijacked
    /// stream when stdin ends (`CloseWrite`) and still reads the output that follows.
    public static func configure(_ bootstrap: ServerBootstrap) -> ServerBootstrap {
        bootstrap.childChannelOption(.allowRemoteHalfClosure, value: true)
    }

    /// Installs the HTTP pipeline on an accepted connection.
    ///
    /// `.forwardBytes` keeps bytes that follow an upgraded request, such as stdin typed before
    /// the 101 was read, for the hijacked stream instead of dropping them.
    ///
    /// With `allowedUID`, a connection from any other user is closed before it is read. The
    /// socket's directory already keeps other users out; this holds even if it did not.
    ///
    /// The connecting process is read too (`LOCAL_PEERPID`) and put on each request as its
    /// `peer`, for the engine's folder panel to name. That read is best effort: a connection
    /// whose peer cannot be read is served all the same, with no peer.
    public func initialize(_ channel: any Channel, allowedUID: uid_t? = nil) -> EventLoopFuture<Void> {
        let router = self.router
        let limits = self.limits
        let log = self.log
        let install: @Sendable (DockerPeer?) -> EventLoopFuture<Void> = { peer in
            channel.eventLoop.makeCompletedFuture {
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let handler = DockerHTTPHandler(router: router, limits: limits, log: log, encoder: encoder, decoder: decoder, peer: peer)
                try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])
            }
        }
        let provider = channel as? any SocketOptionProvider
        guard let allowedUID else {
            return Self.peer(of: provider, on: channel.eventLoop).flatMap(install)
        }
        guard let provider else {
            return channel.eventLoop.makeFailedFuture(DockerAPIError(.forbidden, "cannot identify the client"))
        }
        let credentials: EventLoopFuture<xucred> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERCRED))
        return credentials.flatMap { peer in
            guard peer.cr_version == XUCRED_VERSION, peer.cr_uid == allowedUID else {
                log.warning("refused a connection from another user", metadata: ["uid": "\(peer.cr_uid)"])
                return channel.close().flatMapThrowing { throw DockerAPIError(.forbidden, "connection from another user") }
            }
            return Self.peer(of: provider, on: channel.eventLoop).flatMap(install)
        }
    }

    /// The process that connected, or nil when the socket cannot say: not a unix socket, or a
    /// peer that has already gone.
    static func peer(of provider: (any SocketOptionProvider)?, on eventLoop: any EventLoop) -> EventLoopFuture<DockerPeer?> {
        guard let provider else { return eventLoop.makeSucceededFuture(nil) }
        let pid: EventLoopFuture<pid_t> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERPID))
        return pid.map { DockerPeer.resolve(pid: $0) }.recover { _ in nil }
    }
}
