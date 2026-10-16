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

/// Limits on what one connection may make the service hold.
public struct DockerHTTPLimits: Sendable {
    /// The largest request body read into memory. A route that takes more spools its body to
    /// a file under its own bound (`DockerBodyPolicy.spool`); any other is refused with 413.
    public var maxBodyBytes: Int
    /// The most header fields a request may have.
    public var maxHeaderFields: Int
    /// The most requests read ahead of the one being answered on a keep-alive connection.
    public var maxQueuedRequests: Int
    /// Where spooled bodies are written; the system's temporary directory when nil.
    public var spoolDirectory: URL?

    public init(maxBodyBytes: Int = 16 << 20, maxHeaderFields: Int = 100, maxQueuedRequests: Int = 8, spoolDirectory: URL? = nil) {
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderFields = maxHeaderFields
        self.maxQueuedRequests = maxQueuedRequests
        self.spoolDirectory = spoolDirectory
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
    /// The process on the other end, put on every request this connection carries.
    private let peer: DockerPeer?

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    /// The file the body being read goes to, for a route that spools its body.
    private var spool: DockerSpooledBody?
    /// Reading stopped until the spool's writes catch up.
    private var readPaused = false
    /// Set when the request being read broke a limit; its remaining parts are dropped.
    private var refused: DockerAPIError?
    private var queue: [Queued] = []
    private var answering = false
    /// The spooled body of the request being answered, deleted once it has been answered.
    private var answeringBodyFile: URL?
    /// The connection has been handed to a hijacked stream and is no longer HTTP.
    private var hijacked = false
    /// The route or stream producer running for this connection, cancelled if the client goes,
    /// so a `wait` or a followed log holds nothing for a client that has left.
    private var cancelRunning: (@Sendable () -> Void)?

    init(
        router: DockerRouter, limits: DockerHTTPLimits, log: Logger,
        encoder: HTTPResponseEncoder, decoder: ByteToMessageHandler<HTTPRequestDecoder>, peer: DockerPeer? = nil
    ) {
        self.peer = peer
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
            if refused == nil {
                startSpool(for: next, context: context)
            }
        case .body(var chunk):
            guard refused == nil else { return }
            if let spool {
                guard !spool.wouldExceed(chunk.readableBytes) else {
                    refused = DockerAPIError(.payloadTooLarge, "request body is larger than \(spool.maxBytes) bytes")
                    spool.discard()
                    self.spool = nil
                    resumeReading(context: context)
                    return
                }
                spool.append(chunk) { [weak self] in
                    // Read again once the disk has caught up with the body being read, or once
                    // that body is no longer being read.
                    guard let self, self.readPaused else { return }
                    if let current = self.spool, current.pending >= DockerSpooledBody.highWater { return }
                    self.resumeReading(context: context)
                }
                if spool.pending >= DockerSpooledBody.highWater, !readPaused {
                    readPaused = true
                    context.channel.setOption(.autoRead, value: false).whenFailure { _ in }
                }
                return
            }
            if body.readableBytes + chunk.readableBytes > limits.maxBodyBytes {
                refused = DockerAPIError(.payloadTooLarge, "request body is larger than \(limits.maxBodyBytes) bytes")
                body.clear()
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            guard queue.count < limits.maxQueuedRequests else {
                // A client this far ahead of its answers is not one we need to keep up with.
                spool?.discard()
                spool = nil
                context.close(promise: nil)
                return
            }
            let entry = Queued(head: head)
            queue.append(entry)
            if let refused {
                entry.parsed = .failure(refused)
            } else if let spool {
                // Answered once the body is all on disk; later requests wait their turn.
                self.spool = nil
                resumeReading(context: context)
                spool.finish().assumeIsolated().whenComplete { result in
                    switch result {
                    case .success(let file):
                        entry.bodyFile = file
                        entry.parsed = Self.parse(head, body: ByteBuffer(), bodyFile: file, peer: self.peer)
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: spool.url)
                        entry.parsed = .failure(DockerAPIError.internalError("could not store the request body: \(error)"))
                    }
                    self.answerNext(context: context)
                }
                body = ByteBuffer()
                return
            } else {
                entry.parsed = Self.parse(head, body: body, bodyFile: nil, peer: peer)
            }
            body = ByteBuffer()
            answerNext(context: context)
        }
    }

    /// A request read whole, waiting for its turn; a spooled one is ready once its body is on
    /// disk.
    private final class Queued {
        let head: HTTPRequestHead
        var parsed: Result<DockerRequest, DockerAPIError>?
        var bodyFile: URL?

        init(head: HTTPRequestHead) {
            self.head = head
        }
    }

    private static func parse(_ head: HTTPRequestHead, body: ByteBuffer, bodyFile: URL?, peer: DockerPeer?) -> Result<DockerRequest, DockerAPIError> {
        do {
            return .success(
                try DockerRequest(method: head.method, uri: head.uri, headers: head.headers, body: body, bodyFile: bodyFile, peer: peer))
        } catch {
            return .failure(error)
        }
    }

    /// Starts writing the body to a file when the route that will answer `head` spools it.
    private func startSpool(for head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let target = try? DockerRequest(method: head.method, uri: head.uri, headers: [:], body: ByteBuffer()),
            case .spool(let maxBytes) = router.bodyPolicy(method: target.method, segments: target.segments)
        else { return }
        do {
            spool = try DockerSpooledBody(
                directory: limits.spoolDirectory ?? FileManager.default.temporaryDirectory, maxBytes: maxBytes, eventLoop: context.eventLoop)
        } catch {
            log.error("could not make a file for a request body", metadata: ["error": "\(error)"])
            refused = DockerAPIError.internalError("could not store the request body")
        }
    }

    private func resumeReading(context: ChannelHandlerContext) {
        guard readPaused else { return }
        readPaused = false
        context.channel.setOption(.autoRead, value: true).whenFailure { _ in }
    }

    /// Deletes every spooled body this connection still holds.
    private func discardBodies() {
        spool?.discard()
        spool = nil
        for entry in queue {
            if let file = entry.bodyFile { try? FileManager.default.removeItem(at: file) }
        }
        if let file = answeringBodyFile {
            try? FileManager.default.removeItem(at: file)
            answeringBodyFile = nil
        }
    }

    private func answerNext(context: ChannelHandlerContext) {
        guard !answering, !hijacked, let parsed = queue.first?.parsed else { return }
        answering = true
        let entry = queue.removeFirst()
        let head = entry.head
        answeringBodyFile = entry.bodyFile
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

        case .stream(let status, let contentType, let extra, let produce):
            // No length, so the encoder sends the body chunked; the head goes out now.
            var headers = Self.headers(contentType: contentType, keepAlive: keepAlive)
            headers.add(contentsOf: extra)
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
            hijack(context: context, multiplexed: multiplexed, upgrade: Self.asksToUpgrade(request), body: body)
        }
    }

    private func finished(keepAlive: Bool, context: ChannelHandlerContext) {
        answering = false
        cancelRunning = nil
        if let file = answeringBodyFile {
            try? FileManager.default.removeItem(at: file)
            answeringBodyFile = nil
        }
        guard keepAlive else {
            context.close(promise: nil)
            return
        }
        answerNext(context: context)
    }

    /// Whether a request asks for its connection to be upgraded, as dockerd decides it: by an
    /// `Upgrade` header being there at all.
    static func asksToUpgrade(_ request: HTTPRequestHead) -> Bool {
        request.headers.contains(name: "Upgrade")
    }

    /// Answers `101 UPGRADED` and gives the connection to `body` as raw bytes.
    ///
    /// A request that did not ask to upgrade gets `200 OK` instead, as dockerd answers it, with
    /// neither a length nor chunks: the stream is the body, and it ends when this side closes.
    /// A client that sent no `Upgrade` header reads a 101 as an interim answer and waits for
    /// another, which never comes; docker-java does so for an exec start without stdin.
    ///
    /// The encoder goes first, so the raw 101 can be written. The stream's handlers are added
    /// before the decoder leaves, so the bytes it still holds (`.forwardBytes`: stdin typed
    /// before the 101 was read) have somewhere to go; this handler passes on anything that
    /// reaches it once hijacked, so they arrive whichever of the two leaves first.
    private func hijack(
        context: ChannelHandlerContext, multiplexed: Bool, upgrade: Bool,
        body: @escaping @Sendable (DockerHijackedStream) async throws -> Void
    ) {
        hijacked = true
        for entry in queue {
            if let file = entry.bodyFile { try? FileManager.default.removeItem(at: file) }
        }
        queue.removeAll()
        let channel = context.channel
        let pipeline = context.pipeline.syncOperations
        do {
            pipeline.removeHandler(encoder).assumeIsolated().whenFailure { _ in channel.close(promise: nil) }
            let contentType = multiplexed ? "application/vnd.docker.multiplexed-stream" : "application/vnd.docker.raw-stream"
            let head =
                upgrade
                ? "HTTP/1.1 101 UPGRADED\r\nContent-Type: \(contentType)\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n"
            context.writeAndFlush(NIOAny(ByteBuffer(string: head)), promise: nil)
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
            discardBodies()
            queue.removeAll()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelRunning?()
        cancelRunning = nil
        discardBodies()
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
