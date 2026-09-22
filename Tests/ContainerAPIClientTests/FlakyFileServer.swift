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
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// A loopback file server that misbehaves on request: it can stop sending without hanging up,
/// hang up early, ignore ranges, refuse them, or serve a file that has changed.
///
/// Requests are answered from a script, one entry each, and the last entry repeats.
final class FlakyFileServer: Sendable {
    enum Ending: Sendable {
        /// Send everything that was asked for and end the response.
        case finish
        /// Send what `send` allows, then keep the connection open and say nothing more.
        case stall
        /// Send what `send` allows, then close the connection.
        case hangUp
        /// Send what `send` allows, then close the connection once `releaseHeld()` says the
        /// client has all of it. Hanging up straight away races the client's reader, and how
        /// much it had kept by then depends on how busy the machine is.
        case hold
    }

    struct Reply: Sendable {
        /// An answer other than the file: this status and an empty body.
        var status: HTTPResponseStatus?
        var honoursRange = true
        var advertisesRanges = true
        /// How much of the body to send before `ending`. nil sends all of it.
        var send: Int?
        var ending = Ending.finish
        var etag: String? = "\"v1\""
        var lastModified: String?
        /// A different file from this reply on, as if it had been replaced on the server.
        var payload: [UInt8]?
    }

    struct Seen: Sendable, Equatable {
        let range: String?
        let ifRange: String?
    }

    private struct Held: Sendable {
        let channel: any Channel
        /// How far into the file the bytes sent on this connection reach.
        let offset: Int
    }

    private struct State: Sendable {
        var script: [Reply]
        var payload: [UInt8]
        var seen: [Seen] = []
        var held: Held?
    }

    /// The lock cannot be copied into the handlers' closure, so a reference to it is.
    private final class Shared: Sendable {
        let state: Mutex<State>
        init(_ state: State) { self.state = Mutex(state) }
    }

    let url: URL
    private let shared: Shared
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    init(serving payload: [UInt8], script: [Reply]) throws {
        precondition(!script.isEmpty)
        let shared = Shared(State(script: script, payload: payload))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.shared = shared
        self.group = group

        let next: @Sendable (HTTPRequestHead) -> (Reply, [UInt8]) = { head in
            shared.state.withLock { state in
                let reply = state.script[min(state.seen.count, state.script.count - 1)]
                state.seen.append(Seen(range: head.headers.first(name: "Range"), ifRange: head.headers.first(name: "If-Range")))
                if let payload = reply.payload { state.payload = payload }
                return (reply, state.payload)
            }
        }
        let hold: @Sendable (any Channel, Int) -> Void = { channel, offset in
            shared.state.withLock { $0.held = Held(channel: channel, offset: offset) }
        }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(next: next, hold: hold))
                }
            }
        do {
            self.channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
        // The path stands in for a secret: nothing the downloader logs or throws may repeat it.
        self.url = URL(string: "http://127.0.0.1:\(self.channel.localAddress?.port ?? 0)/secret-token/payload.bin")!
    }

    var seen: [Seen] { shared.state.withLock { $0.seen } }

    /// How much of the file the client must have before the held connection may be closed.
    var heldOffset: Int? { shared.state.withLock { $0.held?.offset } }

    /// Closes the connection a `.hold` reply left open.
    func releaseHeld() {
        let held = shared.state.withLock { state in
            defer { state.held = nil }
            return state.held
        }
        held?.channel.close(promise: nil)
    }

    /// Closes the listener and every connection still open, the stalled ones included.
    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let next: @Sendable (HTTPRequestHead) -> (Reply, [UInt8])
        private let hold: @Sendable (any Channel, Int) -> Void
        private var head: HTTPRequestHead?

        init(
            next: @escaping @Sendable (HTTPRequestHead) -> (Reply, [UInt8]),
            hold: @escaping @Sendable (any Channel, Int) -> Void
        ) {
            self.next = next
            self.hold = hold
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
            case .body:
                break
            case .end:
                guard let head else { return }
                self.head = nil
                respond(to: head, context: context)
            }
        }

        private func respond(to request: HTTPRequestHead, context: ChannelHandlerContext) {
            let (reply, payload) = next(request)
            var headers = HTTPHeaders()

            if let status = reply.status {
                headers.add(name: "Content-Length", value: "0")
                if status == .rangeNotSatisfiable {
                    headers.add(name: "Content-Range", value: "bytes */\(payload.count)")
                }
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                return
            }

            var start = 0
            var status = HTTPResponseStatus.ok
            if reply.honoursRange, let from = Self.rangeStart(request.headers.first(name: "Range")) {
                let condition = request.headers.first(name: "If-Range")
                // A condition that names another version of the file gets the whole of this one.
                if condition == nil || condition == reply.etag || condition == reply.lastModified {
                    guard from < payload.count else {
                        headers.add(name: "Content-Length", value: "0")
                        headers.add(name: "Content-Range", value: "bytes */\(payload.count)")
                        context.write(
                            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .rangeNotSatisfiable, headers: headers))), promise: nil)
                        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                        return
                    }
                    start = from
                    status = .partialContent
                }
            }

            let body = payload[start...]
            headers.add(name: "Content-Length", value: "\(body.count)")
            if status == .partialContent {
                headers.add(name: "Content-Range", value: "bytes \(start)-\(payload.count - 1)/\(payload.count)")
            }
            if reply.advertisesRanges { headers.add(name: "Accept-Ranges", value: "bytes") }
            if let etag = reply.etag { headers.add(name: "ETag", value: etag) }
            if let lastModified = reply.lastModified { headers.add(name: "Last-Modified", value: lastModified) }
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)

            let count = min(reply.send ?? body.count, body.count)
            var sent = 0
            while sent < count {
                let size = min(8 * 1024, count - sent)
                var buffer = context.channel.allocator.buffer(capacity: size)
                buffer.writeBytes(body[(body.startIndex + sent)..<(body.startIndex + sent + size)])
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                sent += size
            }

            // A response sent in full is a finished one, whatever its ending asked for.
            if count == body.count {
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            context.flush()
            switch reply.ending {
            case .stall:
                break
            case .hold:
                hold(context.channel, start + count)
            case .finish, .hangUp:
                context.close(promise: nil)
            }
        }

        /// The start of an open-ended `bytes=N-` range, the only kind the downloader sends.
        private static func rangeStart(_ value: String?) -> Int? {
            guard let value, value.hasPrefix("bytes="), value.hasSuffix("-") else { return nil }
            return Int(value.dropFirst("bytes=".count).dropLast())
        }
    }
}
