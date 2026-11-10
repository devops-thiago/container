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

import ContainerPersistence
import ContainerizationError
import Foundation
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing

@testable import ClusterHostStoreService

struct LookupStatusTests {
    @Test func notFoundIs404() {
        #expect(HostStoreServer.status(for: ContainerizationError(.notFound, message: "missing")) == .notFound)
    }

    @Test func invalidArgumentIs400() {
        #expect(HostStoreServer.status(for: ContainerizationError(.invalidArgument, message: "bad digest")) == .badRequest)
    }

    @Test func otherErrorIs500() {
        #expect(HostStoreServer.status(for: CancellationError()) == .internalServerError)
    }
}

struct ConnectionLimitTests {
    @Test func acquireFailsPastMax() {
        let limit = ConnectionLimit(max: 2)
        #expect(limit.acquire())
        #expect(limit.acquire())
        #expect(!limit.acquire())
    }

    @Test func releaseFreesASlot() {
        let limit = ConnectionLimit(max: 1)
        #expect(limit.acquire())
        limit.release()
        #expect(limit.acquire())
    }
}

/// An error that nothing in NIO or the host store knows.
private struct UnknownError: Error, Equatable {}

/// The error NIO throws when it cannot set up an accepted socket. It has no public
/// initializer and no stored properties, so the empty tuple has its layout.
private func fcntlFailedError() -> NIOFcntlFailedError {
    unsafeBitCast((), to: NIOFcntlFailedError.self)
}

private func acceptError(_ code: CInt) -> IOError {
    IOError(errnoCode: code, reason: "accept")
}

struct AcceptErrorClassificationTests {
    @Test(arguments: [ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM])
    func listenerSurvivesTransientErrno(code: CInt) {
        #expect(AcceptErrorHandler.keepsListening(after: acceptError(code)))
    }

    @Test func listenerSurvivesFailedFcntl() {
        #expect(AcceptErrorHandler.keepsListening(after: fcntlFailedError()))
    }

    @Test(arguments: [EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP, EPERM])
    func listenerClosesOnOtherErrno(code: CInt) {
        #expect(!AcceptErrorHandler.keepsListening(after: acceptError(code)))
    }

    @Test func listenerClosesOnOtherErrors() {
        #expect(!AcceptErrorHandler.keepsListening(after: ChannelError.eof))
        #expect(!AcceptErrorHandler.keepsListening(after: UnknownError()))
    }
}

/// The listening channel's handlers, driven without a socket.
struct AcceptErrorHandlerTests {
    /// Counts the reads that reach the head of the pipeline, where the socket would accept.
    private final class ReadCounter: ChannelOutboundHandler {
        typealias OutboundIn = NIOAny

        private(set) var reads = 0

        func read(context: ChannelHandlerContext) {
            reads += 1
            context.read()
        }
    }

    private static func channel(_ first: [any ChannelHandler] = []) -> EmbeddedChannel {
        EmbeddedChannel(handlers: first + AcceptErrorHandler.handlers(log: Logger(label: "host-store-accept-tests")))
    }

    @Test(arguments: [ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM])
    func transientErrnoGoesNoFurther(code: CInt) throws {
        let channel = Self.channel()
        channel.pipeline.fireErrorCaught(acceptError(code))
        try channel.throwIfErrorCaught()
        _ = try channel.finish()
    }

    @Test func failedFcntlGoesNoFurther() throws {
        let channel = Self.channel()
        channel.pipeline.fireErrorCaught(fcntlFailedError())
        try channel.throwIfErrorCaught()
        _ = try channel.finish()
    }

    @Test func otherErrnoIsPassedOn() throws {
        let channel = Self.channel()
        channel.pipeline.fireErrorCaught(acceptError(EBADF))
        let error = #expect(throws: IOError.self) { try channel.throwIfErrorCaught() }
        #expect(error?.errnoCode == EBADF)
        _ = try channel.finish()
    }

    @Test func otherErrorIsPassedOn() throws {
        let channel = Self.channel()
        channel.pipeline.fireErrorCaught(UnknownError())
        #expect(throws: UnknownError.self) { try channel.throwIfErrorCaught() }
        _ = try channel.finish()
    }

    /// The connection a failed accept left in the backlog fails the next accept the same
    /// way, so the next read waits.
    @Test func transientErrnoHoldsBackTheNextAccept() throws {
        let counter = ReadCounter()
        let channel = Self.channel([counter])
        channel.read()
        #expect(counter.reads == 1)

        channel.pipeline.fireErrorCaught(acceptError(EMFILE))
        channel.read()
        #expect(counter.reads == 1)
        _ = try channel.finish()
    }
}

/// The server on a real socket, with errors put on its listening channel as NIO would after
/// a failed accept.
struct HostStoreServerAcceptTests {
    /// Binds a server in a directory of its own and serves it for as long as `body` runs.
    /// `serving` is the task that ends when the server does.
    private static func withServer(
        _ body: (_ listener: HTTPListener, _ socketPath: String, _ serving: Task<Void, any Error>) async throws -> Void
    ) async throws {
        let directory = "/tmp/hs-accept-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        // Binding narrows the process umask for a moment, and the suite's tests overlap: the
        // mode is set outright so that a directory made in that moment can still be entered.
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/hs.sock"
        let log = Logger(label: "host-store-accept-tests")
        let server = HostStoreServer(containerSystemConfig: ContainerSystemConfig(), log: log)

        let listener = try await HostStoreServer.bind(socketPath: path, log: log)
        let serving = Task { try await server.accept(from: listener, socketPath: path) }
        defer { listener.channel.close(promise: nil) }
        try await body(listener, path, serving)
    }

    /// Puts `error` on the listening channel and returns once its handlers have seen it.
    private static func fail(_ listener: HTTPListener, with error: any Error) async throws {
        listener.channel.pipeline.fireErrorCaught(error)
        try await listener.channel.eventLoop.submit {}.get()
    }

    /// The status the server answers a GET of `uri` with, on a new connection.
    private static func status(of uri: String, socketPath: String) async throws -> HTTPResponseStatus? {
        let client = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(unixDomainSocketPath: socketPath) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        return try await client.executeThenClose { inbound, outbound in
            let headers: HTTPHeaders = ["Host": "host-store", "Connection": "close"]
            try await outbound.write(.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)))
            try await outbound.write(.end(nil))
            for try await part in inbound {
                if case .head(let head) = part {
                    return head.status
                }
            }
            return nil
        }
    }

    @Test func servesAfterAcceptErrorsTheListenerSurvives() async throws {
        try await Self.withServer { listener, path, _ in
            for code in AcceptErrorHandler.transientErrnos.sorted() {
                try await Self.fail(listener, with: acceptError(code))
            }
            try await Self.fail(listener, with: fcntlFailedError())
            #expect(try await Self.status(of: "/nothing", socketPath: path) == .notFound)
        }
    }

    @Test func otherErrorEndsTheServer() async throws {
        try await Self.withServer { listener, _, serving in
            try await Self.fail(listener, with: UnknownError())
            // A server that ignored the error would be waited on forever. Closing the
            // listener ends it with another error, which fails the expectation instead.
            let deadline = Task {
                try await Task.sleep(for: .seconds(30))
                listener.channel.close(promise: nil)
            }
            defer { deadline.cancel() }
            await #expect(throws: UnknownError.self) { try await serving.value }
        }
    }

    @Test func closedListenerEndsTheServerWithAnError() async throws {
        try await Self.withServer { listener, path, serving in
            #expect(try await Self.status(of: "/nothing", socketPath: path) == .notFound)
            try await listener.channel.close()
            let error = await #expect(throws: ContainerizationError.self) { try await serving.value }
            #expect(error?.code == .internalError)
        }
    }
}
