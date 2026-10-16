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

/// Limits on what one connection may make the service hold.
public struct DockerHTTPLimits: Sendable {
    /// The largest request body read into memory. A larger body is refused with 413, unless
    /// `spool` writes it to a file.
    public var maxBodyBytes: Int
    /// The most header fields a request may have.
    public var maxHeaderFields: Int
    /// The most requests read ahead of the one being answered on a keep-alive connection.
    public var maxQueuedRequests: Int
    /// The bodies written to a file as they arrive, with their own bound, instead of being
    /// held in memory under `maxBodyBytes`.
    public var spool: DockerBodySpool?

    public init(maxBodyBytes: Int = 16 << 20, maxHeaderFields: Int = 100, maxQueuedRequests: Int = 8, spool: DockerBodySpool? = nil) {
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderFields = maxHeaderFields
        self.maxQueuedRequests = maxQueuedRequests
        self.spool = spool
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
    /// Requests read and not yet answered. A spooled one is ready once its file is written.
    private var queue: [(HTTPRequestHead, EventLoopFuture<Result<DockerRequest, DockerAPIError>>)] = []
    private var answering = false
    /// The body being written to a file, while one is.
    private var spooling: Spooling?
    /// Bytes handed to the file and not yet written. Reading stops past `spoolHighWater`.
    private var spoolInFlight = 0
    private var readingPaused = false
    private static let spoolHighWater = 4 << 20
    private static let spoolLowWater = 1 << 20
    /// The spooled body of the request being answered, deleted once the answer is sent.
    private var answeringFile: URL?

    private struct Spooling {
        let url: URL
        let handle: NIOFileHandle
        var written: Int64 = 0
        /// The writes so far, in order.
        var writes: EventLoopFuture<Void>
    }
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
            if refused == nil, let spool = limits.spool, let segments = DockerRequest.routeSegments(of: next.uri), spool.accepts(next.method, segments) {
                startSpooling(spool, context: context)
            }
        case .body(var chunk):
            guard refused == nil else { return }
            if spooling != nil {
                spool(chunk, context: context)
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
            let request: EventLoopFuture<Result<DockerRequest, DockerAPIError>>
            if let spooling {
                self.spooling = nil
                request = finishSpooling(spooling, head: head, context: context)
            } else if let refused {
                request = context.eventLoop.makeSucceededFuture(.failure(refused))
            } else {
                do {
                    request = context.eventLoop.makeSucceededFuture(
                        .success(try DockerRequest(method: head.method, uri: head.uri, headers: head.headers, body: body)))
                } catch {
                    request = context.eventLoop.makeSucceededFuture(.failure(error))
                }
            }
            body = ByteBuffer()
            guard queue.count < limits.maxQueuedRequests else {
                // A client this far ahead of its answers is not one we need to keep up with.
                Self.removeFile(of: request)
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
        let (head, pending) = queue.removeFirst()
        pending.assumeIsolated().whenSuccess { parsed in
            self.answer(parsed, for: head, context: context)
        }
    }

    private func answer(_ parsed: Result<DockerRequest, DockerAPIError>, for head: HTTPRequestHead, context: ChannelHandlerContext) {
        let router = self.router
        let promise = context.eventLoop.makePromise(of: DockerResponse.self)
        switch parsed {
        case .success(let request):
            answeringFile = request.bodyFile
            let task = Task { await router.respond(to: request) }
            cancelRunning = { task.cancel() }
            // A client that left while its body was being written is not waited for.
            if !context.channel.isActive {
                task.cancel()
            }
            promise.completeWithTask { await task.value }
        case .failure(let error):
            promise.succeed(.error(error))
        }
        promise.futureResult.assumeIsolated().whenSuccess { response in
            self.send(response, for: head, context: context)
        }
    }

    // MARK: Spooling

    private func startSpooling(_ spool: DockerBodySpool, context: ChannelHandlerContext) {
        let url = spool.directory.appending(path: "docker-api-body-\(UUID().uuidString)")
        do {
            let handle = try NIOFileHandle(
                _deprecatedPath: url.path(percentEncoded: false), mode: .write, flags: .allowFileCreation(posixMode: 0o600))
            spooling = Spooling(url: url, handle: handle, writes: context.eventLoop.makeSucceededVoidFuture())
        } catch {
            log.error("could not store a request body", metadata: ["error": "\(error)"])
            refused = .internalError("could not store the request body: \(error)")
        }
    }

    /// Queues `chunk` behind the writes before it, and stops reading while too much is queued.
    private func spool(_ chunk: ByteBuffer, context: ChannelHandlerContext) {
        guard var spooling, let limit = limits.spool?.maxBytes else { return }
        let bytes = chunk.readableBytes
        guard spooling.written + Int64(bytes) <= limit else {
            refused = DockerAPIError(.payloadTooLarge, "request body is larger than \(limit) bytes")
            self.spooling = nil
            discard(spooling)
            return
        }
        spooling.written += Int64(bytes)
        spoolInFlight += bytes
        let fileIO = DockerScratchFile.fileIO
        let handle = spooling.handle
        let eventLoop = context.eventLoop
        spooling.writes = spooling.writes.flatMap { fileIO.write(fileHandle: handle, buffer: chunk, eventLoop: eventLoop) }
        spooling.writes.assumeIsolated().whenComplete { _ in
            self.spoolInFlight -= bytes
            if self.readingPaused && self.spoolInFlight <= Self.spoolLowWater {
                self.readingPaused = false
                try? context.channel.syncOptions?.setOption(.autoRead, value: true)
            }
        }
        self.spooling = spooling
        if !readingPaused && spoolInFlight > Self.spoolHighWater {
            readingPaused = true
            try? context.channel.syncOptions?.setOption(.autoRead, value: false)
        }
    }

    /// The request, once its body is all in the file.
    private func finishSpooling(
        _ spooling: Spooling, head: HTTPRequestHead, context: ChannelHandlerContext
    ) -> EventLoopFuture<Result<DockerRequest, DockerAPIError>> {
        let promise = context.eventLoop.makePromise(of: Result<DockerRequest, DockerAPIError>.self)
        spooling.writes.assumeIsolated().whenComplete { result in
            try? spooling.handle.close()
            do {
                try result.get()
                promise.succeed(.success(try DockerRequest(method: head.method, uri: head.uri, headers: head.headers, body: ByteBuffer(), bodyFile: spooling.url)))
            } catch let error as DockerAPIError {
                Self.removeFile(spooling.url)
                promise.succeed(.failure(error))
            } catch {
                Self.removeFile(spooling.url)
                promise.succeed(.failure(.internalError("could not store the request body: \(error)")))
            }
        }
        return promise.futureResult
    }

    /// Drops a body being spooled: its file goes once the writes queued for it are done.
    private func discard(_ spooling: Spooling) {
        spooling.writes.assumeIsolated().whenComplete { _ in
            try? spooling.handle.close()
            Self.removeFile(spooling.url)
        }
    }

    /// Deletes a file off the event loop: an image archive can take a while to unlink.
    private static func removeFile(_ url: URL) {
        NIOThreadPool.singleton.submit { _ in try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes the spooled body of a request that will not be answered.
    private static func removeFile(of request: EventLoopFuture<Result<DockerRequest, DockerAPIError>>) {
        request.whenSuccess { parsed in
            if case .success(let request) = parsed, let url = request.bodyFile { removeFile(url) }
        }
    }

    /// Forgets the requests not yet answered and what they spooled, and the body being read.
    private func dropPending() {
        for (_, request) in queue { Self.removeFile(of: request) }
        queue.removeAll()
        if let spooling {
            self.spooling = nil
            discard(spooling)
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
        if let answeringFile {
            self.answeringFile = nil
            Self.removeFile(answeringFile)
        }
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
        dropPending()
        if let answeringFile {
            self.answeringFile = nil
            Self.removeFile(answeringFile)
        }
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
            dropPending()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelRunning?()
        cancelRunning = nil
        dropPending()
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
