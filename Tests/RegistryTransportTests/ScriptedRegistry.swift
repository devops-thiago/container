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

// Copyright © 2026 Apple Inc. and the container project authors.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// A loopback registry that answers every request the same way: a status, headers, and a
/// body it may send only part of before going quiet without hanging up.
final class ScriptedRegistry: Sendable {
    struct Reply: Sendable {
        var status: HTTPResponseStatus = .ok
        var headers: [(String, String)] = []
        var body: [UInt8] = []
        /// How much of the body to send before saying nothing more. nil sends all of it and
        /// ends the response.
        var sendOnly: Int?
    }

    let host = "127.0.0.1"
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    init(_ reply: Reply) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(reply: reply))
                }
            }
        do {
            channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
        port = channel.localAddress!.port!
    }

    func stop() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let reply: Reply

        init(reply: Reply) { self.reply = reply }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .head(let head) = unwrapInboundIn(data) else { return }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(reply.body.count)")
            for (name, value) in reply.headers { headers.add(name: name, value: value) }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: reply.status, headers: headers))), promise: nil)
            let sent = head.method == .HEAD ? 0 : min(reply.sendOnly ?? reply.body.count, reply.body.count)
            if sent > 0 {
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: reply.body[..<sent])))), promise: nil)
            }
            if reply.sendOnly == nil || head.method == .HEAD {
                context.write(wrapOutboundOut(.end(nil)), promise: nil)
            }
            // With part of the body sent and the rest withheld, the connection stays open and
            // silent: what a peer that went quiet looks like.
            context.flush()
        }
    }
}
