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
    public func initialize(_ channel: any Channel) -> EventLoopFuture<Void> {
        let router = self.router
        let limits = self.limits
        let log = self.log
        return channel.eventLoop.makeCompletedFuture {
            let encoder = HTTPResponseEncoder()
            let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
            let handler = DockerHTTPHandler(router: router, limits: limits, log: log, encoder: encoder, decoder: decoder)
            try channel.pipeline.syncOperations.addHandlers([encoder, decoder, handler])
        }
    }
}
