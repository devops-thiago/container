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

import NIO
import Testing

@testable import SocketForwarder

struct TCPHalfCloseTest {
    private let group = MultiThreadedEventLoopGroup.singleton

    /// A client that sends its request and shuts its write side, as `nc -N` and many HTTP/1.0
    /// clients do, still gets the reply the server sends once it has read to the end.
    @Test func aClientThatStopsSendingStillGetsTheReply() async throws {
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(ReplyAtEnd()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let relay = try await TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: try #require(server.localAddress),
            eventLoopGroup: group
        ).run().get()
        defer { relay.close() }

        let client = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: try #require(relay.proxyAddress)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true))
                }
            }
        var reply = ""
        try await client.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: "hello"))
            outbound.finish()
            for try await buffer in inbound { reply += String(buffer: buffer) }
        }
        #expect(reply == "read 5 bytes")
    }
}

/// Counts what arrives and answers once the client has finished sending.
private final class ReplyAtEnd: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var count = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        count += Self.unwrapInboundIn(data).readableBytes
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let event = event as? ChannelEvent, case .inputClosed = event else { return }
        let reply = context.channel.allocator.buffer(string: "read \(count) bytes")
        context.writeAndFlush(Self.wrapOutboundOut(reply), promise: nil)
        context.close(promise: nil)
    }
}
