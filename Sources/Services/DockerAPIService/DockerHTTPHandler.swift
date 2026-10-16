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

/// Limits on what one connection may make the service hold.
public struct DockerHTTPLimits: Sendable {
    /// The largest request body read into memory. Larger bodies (image loads, archive uploads)
    /// are refused with 413 until the routes that take them stream them.
    public var maxBodyBytes: Int
    /// The most header fields a request may have.
    public var maxHeaderFields: Int
    /// The most requests read ahead of the one being answered on a keep-alive connection.
    public var maxQueuedRequests: Int

    public init(maxBodyBytes: Int = 16 << 20, maxHeaderFields: Int = 100, maxQueuedRequests: Int = 8) {
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderFields = maxHeaderFields
        self.maxQueuedRequests = maxQueuedRequests
    }
}

/// Reads whole requests and answers them in order, one at a time per connection.
///
/// It reads the body before answering, unlike NIO's upgrade handler, which drops it: an exec
/// `start` carries its options in the body of the very request that is upgraded. Separate
/// connections are independent, which matters because the CLI opens `attach`, `wait` and
/// `start` side by side and `start` only comes once `wait`'s head has arrived.
final class DockerHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: DockerRouter
    private let limits: DockerHTTPLimits
    private let log: Logger
    private let encoder: HTTPResponseEncoder
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// Set when the request being read broke a limit; its remaining parts are dropped.
    private var refused: DockerAPIError?
    private var queue: [(HTTPRequestHead, Result<DockerRequest, DockerAPIError>)] = []
    private var answering = false
    /// The connection has been handed to a hijacked stream and is no longer HTTP.
    private var hijacked = false
    /// The route or stream producer running for this connection, cancelled if the client goes,
    /// so a `wait` or a followed log holds nothing for a client that has left.
    private var cancelRunning: (@Sendable () -> Void)?

    init(
        router: DockerRouter, limits: DockerHTTPLimits, log: Logger,
        encoder: HTTPResponseEncoder, decoder: ByteToMessageHandler<HTTPRequestDecoder>
    ) {
        self.router = router
        self.limits = limits
        self.log = log
        self.encoder = encoder
        self.decoder = decoder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !hijacked else {
            context.fireChannelRead(data)
            return
        }
        switch unwrapInboundIn(data) {
        case .head(let next):
            head = next
            body.clear()
            refused = next.headers.count > limits.maxHeaderFields ? DockerAPIError(.badRequest, "too many header fields") : nil
        case .body(var chunk):
            guard refused == nil else { return }
            if body.readableBytes + chunk.readableBytes > limits.maxBodyBytes {
                refused = DockerAPIError(.payloadTooLarge, "request body is larger than \(limits.maxBodyBytes) bytes")
                body.clear()
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            let request: Result<DockerRequest, DockerAPIError>
            if let refused {
                request = .failure(refused)
            } else {
                do {
                    request = .success(try DockerRequest(method: head.method, uri: head.uri, headers: head.headers, body: body))
                } catch {
                    request = .failure(error)
                }
            }
            body = ByteBuffer()
            guard queue.count < limits.maxQueuedRequests else {
                // A client this far ahead of its answers is not one we need to keep up with.
                context.close(promise: nil)
                return
            }
            queue.append((head, request))
            answerNext(context: context)
        }
    }

    private func answerNext(context: ChannelHandlerContext) {
        guard !answering, !hijacked, !queue.isEmpty else { return }
        answering = true
        let (head, parsed) = queue.removeFirst()
        let router = self.router
        let promise = context.eventLoop.makePromise(of: DockerResponse.self)
        switch parsed {
        case .success(let request):
            let task = Task { await router.respond(to: request) }
            cancelRunning = { task.cancel() }
            promise.completeWithTask { await task.value }
        case .failure(let error):
            promise.succeed(.error(error))
        }
        promise.futureResult.assumeIsolated().whenSuccess { response in
            self.send(response, for: head, context: context)
        }
    }

    private func send(_ response: DockerResponse, for request: HTTPRequestHead, context: ChannelHandlerContext) {
        let keepAlive = request.isKeepAlive
        switch response {
        case .data(let status, let contentType, let body, let extra):
            var headers = Self.headers(contentType: contentType, keepAlive: keepAlive)
            headers.add(contentsOf: extra)
            headers.add(name: "Content-Length", value: "\(body.readableBytes)")
            context.write(wrapOutboundOut(.head(.init(version: request.version, status: status, headers: headers))), promise: nil)
            if request.method != .HEAD, body.readableBytes > 0 {
                context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
                self.finished(keepAlive: keepAlive, context: context)
            }

        case .stream(let status, let contentType, let produce):
            // No length, so the encoder sends the body chunked; the head goes out now.
            let headers = Self.headers(contentType: contentType, keepAlive: keepAlive)
            context.writeAndFlush(wrapOutboundOut(.head(.init(version: request.version, status: status, headers: headers))), promise: nil)
            let channel = context.channel
            let log = self.log
            let uri = request.uri
            let task = Task {
                do {
                    try await produce(DockerResponseWriter(channel: channel))
                } catch {
                    // The head is gone, so the status cannot change; ending the body early is
                    // all that is left, and the client reports the truncated stream.
                    log.debug("stream ended early", metadata: ["path": "\(uri)", "error": "\(error)"])
                }
            }
            cancelRunning = { task.cancel() }
            // A client that left while the route ran is not cancelled by anything else: the
            // route's own task is done, and this one did not exist when the client went.
            if !context.channel.isActive {
                task.cancel()
            }
            let done = context.eventLoop.makePromise(of: Void.self)
            done.completeWithTask { await task.value }
            done.futureResult.assumeIsolated().whenComplete { _ in
                context.writeAndFlush(self.wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
                    self.finished(keepAlive: keepAlive, context: context)
                }
            }

        case .hijack(let multiplexed, let body):
            hijack(context: context, multiplexed: multiplexed, body: body)
        }
    }

    private func finished(keepAlive: Bool, context: ChannelHandlerContext) {
        answering = false
        cancelRunning = nil
        guard keepAlive else {
            context.close(promise: nil)
            return
        }
        answerNext(context: context)
    }

    /// Answers `101 UPGRADED` and gives the connection to `body` as raw bytes.
    ///
    /// The encoder goes first, so the raw 101 can be written. The stream's handlers are added
    /// before the decoder leaves, so the bytes it still holds (`.forwardBytes`: stdin typed
    /// before the 101 was read) have somewhere to go; this handler passes on anything that
    /// reaches it once hijacked, so they arrive whichever of the two leaves first.
    private func hijack(
        context: ChannelHandlerContext, multiplexed: Bool,
        body: @escaping @Sendable (DockerHijackedStream) async throws -> Void
    ) {
        hijacked = true
        queue.removeAll()
        let channel = context.channel
        let pipeline = context.pipeline.syncOperations
        do {
            pipeline.removeHandler(encoder).assumeIsolated().whenFailure { _ in channel.close(promise: nil) }
            let contentType = multiplexed ? "application/vnd.docker.multiplexed-stream" : "application/vnd.docker.raw-stream"
            let upgrade = "HTTP/1.1 101 UPGRADED\r\nContent-Type: \(contentType)\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
            context.writeAndFlush(NIOAny(ByteBuffer(string: upgrade)), promise: nil)
            let stream = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: channel,
                configuration: .init(isOutboundHalfClosureEnabled: true))
            pipeline.removeHandler(context: context, promise: nil)
            // The decoder hands on the bytes it still holds as a read with no read-complete
            // after it, and the async channel delivers reads only at a read-complete: without
            // one, stdin typed before the 101 would wait for the client's next bytes.
            let decoderRemoved = channel.eventLoop.makePromise(of: Void.self)
            decoderRemoved.futureResult.assumeIsolated().whenComplete { _ in
                channel.pipeline.syncOperations.fireChannelReadComplete()
            }
            pipeline.removeHandler(decoder, promise: decoderRemoved)
            let log = self.log
            Task {
                do {
                    try await stream.executeThenClose { inbound, outbound in
                        try await body(DockerHijackedStream(inbound: inbound, outbound: outbound, multiplexed: multiplexed, channel: channel))
                    }
                } catch {
                    log.debug("hijacked stream ended", metadata: ["error": "\(error)"])
                }
            }
        } catch {
            log.error("could not hijack the connection", metadata: ["error": "\(error)"])
            channel.close(promise: nil)
        }
    }

    static func headers(contentType: String, keepAlive: Bool) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "Api-Version", value: DockerAPIVersion.current.description)
        headers.add(name: "Docker-Experimental", value: "false")
        headers.add(name: "Ostype", value: "linux")
        headers.add(name: "Server", value: "SiliconShip")
        headers.add(name: "Content-Type", value: contentType)
        if !keepAlive { headers.add(name: "Connection", value: "close") }
        return headers
    }

    /// The client stopped sending. Half-closure is allowed on every connection so a hijacked
    /// stream can see stdin end, which also means a client hanging up mid-request arrives here
    /// rather than as the channel going inactive: on a unix socket the two look the same. Before
    /// a hijack, nothing the client still wants needs its input, so treat it as gone, as Go's
    /// server does when its background read sees EOF.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !hijacked, let event = event as? ChannelEvent, event == .inputClosed {
            cancelRunning?()
            cancelRunning = nil
            queue.removeAll()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelRunning?()
        cancelRunning = nil
        queue.removeAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // A request the decoder could not parse: answer the way dockerd's Go server does, then
        // drop the connection, since nothing after it can be framed.
        log.debug("connection error", metadata: ["error": "\(error)"])
        guard !hijacked else {
            context.close(promise: nil)
            return
        }
        let message = DockerAPIError(.badRequest, "malformed request").jsonBody
        var headers = Self.headers(contentType: "application/json", keepAlive: false)
        headers.add(name: "Content-Length", value: "\(message.count)")
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: .badRequest, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: message)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
