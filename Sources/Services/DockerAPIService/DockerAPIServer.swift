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
    public func initialize(_ channel: any Channel, allowedUID: uid_t? = nil) -> EventLoopFuture<Void> {
        let router = self.router
        let limits = self.limits
        let log = self.log
        let install: @Sendable () -> EventLoopFuture<Void> = {
            channel.eventLoop.makeCompletedFuture {
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let handler = DockerHTTPHandler(router: router, limits: limits, log: log, encoder: encoder, decoder: decoder)
                try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])
            }
        }
        guard let allowedUID else { return install() }
        guard let provider = channel as? any SocketOptionProvider else {
            return channel.eventLoop.makeFailedFuture(DockerAPIError(.forbidden, "cannot identify the client"))
        }
        let credentials: EventLoopFuture<xucred> = provider.unsafeGetSocketOption(
            level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERCRED))
        return credentials.flatMap { peer in
            guard peer.cr_version == XUCRED_VERSION, peer.cr_uid == allowedUID else {
                log.warning("refused a connection from another user", metadata: ["uid": "\(peer.cr_uid)"])
                return channel.close().flatMapThrowing { throw DockerAPIError(.forbidden, "connection from another user") }
            }
            return install()
        }
    }
}
