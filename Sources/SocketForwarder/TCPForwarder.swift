//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import NIO
import NIOFoundationCompat
import Synchronization

public struct TCPForwarder: SocketForwarder {
    private let proxyAddress: SocketAddress

    private let serverAddress: SocketAddress

    private let eventLoopGroup: any EventLoopGroup

    private let connectTimeout: TimeAmount

    private let log: Logger?

    /// Which clients may use the forwarder; any other is closed before the backend is dialled.
    /// `nil` takes every client.
    private let acceptsPeer: (@Sendable (SocketAddress) -> Bool)?

    /// How many connections may be relayed at once; beyond it a client is closed at once.
    /// `nil` sets no limit.
    private let connectionLimit: ConnectionLimit?

    public init(
        proxyAddress: SocketAddress,
        serverAddress: SocketAddress,
        eventLoopGroup: any EventLoopGroup,
        connectTimeout: TimeAmount = .seconds(10),
        log: Logger? = nil,
        acceptsPeer: (@Sendable (SocketAddress) -> Bool)? = nil,
        connectionLimit: ConnectionLimit? = nil
    ) throws {
        self.proxyAddress = proxyAddress
        self.serverAddress = serverAddress
        self.eventLoopGroup = eventLoopGroup
        self.connectTimeout = connectTimeout
        self.log = log
        self.acceptsPeer = acceptsPeer
        self.connectionLimit = connectionLimit
    }

    public func run() throws -> EventLoopFuture<SocketForwarderResult> {
        self.log?.trace("frontend - creating listener")

        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            // Reads are paused until the backend connects; the client's bytes are held in the
            // kernel receive buffer instead of an app-level buffer while we wait.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            // A client that is done sending still gets the reply: its end of input is passed
            // on to the backend as a half-close, not taken as the end of the connection.
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let acceptsPeer = self.acceptsPeer, !(channel.remoteAddress.map(acceptsPeer) ?? false) {
                        try channel.pipeline.syncOperations.addHandler(RefusedPeerHandler())
                        return
                    }
                    if let limit = self.connectionLimit {
                        guard limit.acquire() else {
                            self.log?.warning("refusing a connection: too many open", metadata: ["limit": "\(limit.maximum)"])
                            try channel.pipeline.syncOperations.addHandler(RefusedPeerHandler())
                            return
                        }
                        channel.closeFuture.whenComplete { _ in limit.release() }
                    }
                    try channel.pipeline.syncOperations.addHandler(
                        ConnectHandler(serverAddress: self.serverAddress, connectTimeout: self.connectTimeout, log: log)
                    )
                }
            }

        return
            bootstrap
            .bind(to: self.proxyAddress)
            .map { SocketForwarderResult(channel: $0) }
    }
}

/// Closes a connection from a client the forwarder does not serve, as soon as it is up.
final class RefusedPeerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

/// A count of open connections shared by forwarders, with a ceiling.
public final class ConnectionLimit: Sendable {
    public let maximum: Int
    private let open = Mutex(0)

    public init(maximum: Int) {
        self.maximum = maximum
    }

    /// The connections open now.
    public var current: Int { open.withLock { $0 } }

    /// Takes a place, or answers false when every place is taken.
    func acquire() -> Bool {
        open.withLock { count in
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }

    func release() {
        open.withLock { $0 -= 1 }
    }
}
