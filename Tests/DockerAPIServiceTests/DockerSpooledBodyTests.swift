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
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import DockerAPIService

/// Bodies a route spools to a file, over a real unix socket.
@Suite(.timeLimit(.minutes(1)))
struct DockerSpooledBodyTests {
    final class Spool {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dapi-spool-\(UUID().uuidString.prefix(8))")

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"] }
    }

    /// `PUT /upload` spools up to 64 KiB and answers with what its file holds; `POST /small`
    /// keeps the server's 4 KiB in-memory limit.
    static func start(_ spool: Spool) async throws -> DockerAPIServerTests.Harness {
        try await DockerAPIServerTests.Harness.start(limits: DockerHTTPLimits(maxBodyBytes: 4 << 10, spoolDirectory: spool.directory)) { router in
            router.add(.PUT, "/upload", body: .spool(maxBytes: 64 << 10)) { request, _ in
                guard let file = request.bodyFile else { return .text("no file") }
                let data = try Data(contentsOf: file)
                return .text("\(request.body.readableBytes) \(data.count) \(data.first.map { String(UnicodeScalar($0)) } ?? "-")")
            }
            router.add(.POST, "/small") { request, _ in .text("\(request.body.readableBytes)") }
        }
    }

    static func upload(_ count: Int, byte: Character = "u", path: String = "/upload", method: String = "PUT", keepAlive: Bool = false) -> String {
        "\(method) /v1.48\(path) HTTP/1.1\r\nHost: d\r\n\(keepAlive ? "" : "Connection: close\r\n")Content-Length: \(count)\r\n\r\n"
            + String(repeating: byte, count: count)
    }

    @Test("a spooled route takes a body past the in-memory limit in a file, which is gone once answered")
    func spooled() async throws {
        let spool = try Spool()
        let server = try await Self.start(spool)
        defer { Task { try? await server.stop() } }
        try await server.withClient { client in
            try await client.send(Self.upload(40 << 10))
            let answer = try await client.readToEnd()
            #expect(answer.hasPrefix("HTTP/1.1 200"))
            // In the file, none of it in memory.
            #expect(answer.hasSuffix("0 \(40 << 10) u"))
        }
        #expect(await StreamHarness.eventually { spool.files.isEmpty })
    }

    @Test("past the route's own bound it is a 413 and its file is deleted; a route that does not spool keeps the memory limit")
    func bounds() async throws {
        let spool = try Spool()
        let server = try await Self.start(spool)
        defer { Task { try? await server.stop() } }
        try await server.withClient { client in
            try await client.send(Self.upload(80 << 10))
            #expect(try await client.readToEnd().hasPrefix("HTTP/1.1 413"))
        }
        try await server.withClient { client in
            try await client.send(Self.upload(8 << 10, path: "/small", method: "POST"))
            #expect(try await client.readToEnd().hasPrefix("HTTP/1.1 413"))
        }
        // Control: under the memory limit the other route reads its body in memory.
        try await server.withClient { client in
            try await client.send(Self.upload(2 << 10, path: "/small", method: "POST"))
            #expect(try await client.readToEnd().hasSuffix("\r\n\r\n\(2 << 10)"))
        }
        #expect(await StreamHarness.eventually { spool.files.isEmpty })
    }

    @Test("requests sent behind a spooled one on the same connection are answered after it, in order")
    func pipelined() async throws {
        let spool = try Spool()
        let server = try await Self.start(spool)
        defer { Task { try? await server.stop() } }
        try await server.withClient { client in
            try await client.send(
                Self.upload(30 << 10, byte: "a", keepAlive: true) + Self.upload(10, path: "/small", method: "POST", keepAlive: true)
                    + Self.upload(20 << 10, byte: "b"))
            let answers = try await client.readToEnd()
            let bodies = answers.components(separatedBy: "\r\n\r\n").dropFirst().map { $0.components(separatedBy: "HTTP/1.1").first ?? "" }
            #expect(bodies == ["0 \(30 << 10) a", "10", "0 \(20 << 10) b"])
        }
        #expect(await StreamHarness.eventually { spool.files.isEmpty })
    }

    @Test("a client that leaves while its body is being spooled leaves no file behind")
    func abandoned() async throws {
        let spool = try Spool()
        let server = try await Self.start(spool)
        defer { Task { try? await server.stop() } }
        try await server.withClient { client in
            try await client.send("PUT /v1.48/upload HTTP/1.1\r\nHost: d\r\nContent-Length: \(60 << 10)\r\n\r\n" + String(repeating: "x", count: 10 << 10))
            #expect(await StreamHarness.eventually { spool.files.count == 1 })
        }
        #expect(await StreamHarness.eventually { spool.files.isEmpty })
    }
    @Test("disconnect during final spool flush releases the completed body", arguments: [false, true])
    func disconnectDuringFinish(inputClosed: Bool) throws {
        let spool = try Spool()
        let loop = EmbeddedEventLoop()
        let gate = loop.makePromise(of: Void.self)
        var router = DockerRouter()
        router.add(.PUT, "/upload", body: .spool(maxBytes: 64)) { _, _ in
            Issue.record("a disconnected upload must never reach the route")
            return .empty()
        }
        let handler = DockerHTTPHandler(
            router: router, limits: DockerHTTPLimits(spoolDirectory: spool.directory), log: Logger(label: "spool-test"),
            encoder: HTTPResponseEncoder(), decoder: ByteToMessageHandler(HTTPRequestDecoder()),
            finishSpool: { body in body.finish().flatMap { file in gate.futureResult.map { file } } })
        let channel = EmbeddedChannel(handler: handler, loop: loop)
        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/upload")))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        loop.run()
        #expect(spool.files.count == 1, "finished HTTP body remains owned while its flush waits")
        if inputClosed { channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed) } else { channel.pipeline.fireChannelInactive() }
        loop.run()
        gate.succeed(())
        loop.run()
        #expect(spool.files.isEmpty, "late completion must discard the file after the queue was cleared")
        _ = try channel.finish(acceptAlreadyClosed: true)
    }
}
