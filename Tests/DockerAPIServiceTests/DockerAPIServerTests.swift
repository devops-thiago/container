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
import Synchronization
import Testing

@testable import DockerAPIService

/// The service on a real unix socket, driven by a client that writes raw bytes, so what is
/// tested is what the Docker CLI sees on the wire.
@Suite(.timeLimit(.minutes(1)))
struct DockerAPIServerTests {
    struct Harness {
        let server: any Channel
        let path: String

        static func start(
            limits: DockerHTTPLimits = .init(), allowedUID: uid_t? = nil, log: Logger = Logger(label: "DockerAPIService"),
            routes: (inout DockerRouter) -> Void
        ) async throws -> Harness {
            var router = DockerRouter(log: log)
            routes(&router)
            let service = DockerAPIServer(router: router, limits: limits, log: log)
            // Short: a unix socket path has to fit in 104 bytes.
            let path = "/tmp/dapi-\(UUID().uuidString.prefix(8)).sock"
            let server = try await DockerAPIServer.configure(ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton))
                .childChannelInitializer { service.initialize($0, allowedUID: allowedUID) }
                .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
                .get()
            return Harness(server: server, path: path)
        }

        /// Runs `body` with a fresh connection, which is closed when it returns.
        func withClient(_ body: (Client) async throws -> Void) async throws {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelOption(.allowRemoteHalfClosure, value: true)
                .connect(unixDomainSocketPath: path) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel, configuration: .init(isOutboundHalfClosureEnabled: true))
                    }
                }
            try await channel.executeThenClose { inbound, outbound in
                try await body(Client(inbound: inbound, outbound: outbound))
            }
        }

        func stop() async throws {
            try await server.close()
            unlink(path)
        }
    }

    /// A connection that sends raw bytes and reads until it has what it waits for.
    final class Client {
        let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
        var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
        var received = ""

        init(inbound: NIOAsyncChannelInboundStream<ByteBuffer>, outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
            self.outbound = outbound
            self.iterator = inbound.makeAsyncIterator()
        }

        func send(_ text: String) async throws {
            try await outbound.write(ByteBuffer(string: text))
        }

        func closeWrite() {
            outbound.finish()
        }

        /// Reads until `received` contains `marker`; returns everything up to and including it,
        /// and keeps the rest.
        func read(through marker: String) async throws -> String {
            while !received.contains(marker) {
                guard let chunk = try await iterator.next() else {
                    throw ClientError.closedBefore(marker, received)
                }
                received += String(buffer: chunk)
            }
            let end = received.range(of: marker)!.upperBound
            defer { received = String(received[end...]) }
            return String(received[..<end])
        }

        /// Reads until the server closes; returns what arrived.
        func readToEnd() async throws -> String {
            while let chunk = try await iterator.next() {
                received += String(buffer: chunk)
            }
            defer { received = "" }
            return received
        }
    }

    enum ClientError: Error {
        case closedBefore(String, String)
    }

    private static let fakeEngine = FakeEngine()

    struct FakeEngine: EngineSystem {
        func summary() async throws -> EngineSummary {
            EngineSummary(
                engineVersion: "1.6.0", engineCommit: "abc123", kernelVersion: "6.12.28", operatingSystem: "SiliconShip",
                architecture: "aarch64", cpus: 8, memoryBytes: 8 << 30, containers: 3, containersRunning: 1,
                containersStopped: 2, images: 5, name: "test-engine", rootDirectory: "/tmp/engine")
        }
    }

    @Test("ping answers HEAD and GET on one keep-alive connection, in order, with the CLI's headers")
    func pingKeepAlive() async throws {
        let harness = try await Harness.start { SystemRoutes.register(on: &$0, engine: Self.fakeEngine) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("HEAD /_ping HTTP/1.1\r\nHost: docker\r\n\r\nGET /v1.48/_ping HTTP/1.1\r\nHost: docker\r\n\r\n")
            let head = try await client.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 200 OK"))
            #expect(head.contains("api-version: 1.48") || head.contains("Api-Version: 1.48"))
            #expect(head.contains("Builder-Version: 1"))
            #expect(head.contains("Content-Length: 2"))
            // The HEAD carried no body: the next bytes are the GET's status line.
            let get = try await client.read(through: "\r\n\r\nOK")
            #expect(get.hasPrefix("HTTP/1.1 200 OK"))
        }
    }

    @Test("version and info come from the engine, in Docker's field names")
    func versionAndInfo() async throws {
        let harness = try await Harness.start { SystemRoutes.register(on: &$0, engine: Self.fakeEngine) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
            let version = try await client.readToEnd()
            #expect(version.contains(#""ApiVersion":"1.48""#))
            #expect(version.contains(#""MinAPIVersion":"1.44""#))
            #expect(version.contains(#""Version":"1.6.0""#))
        }
        try await harness.withClient { second in
            try await second.send("GET /v1.44/info HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n")
            let info = try await second.readToEnd()
            #expect(info.contains(#""NCPU":8"#))
            #expect(info.contains(#""ContainersRunning":1"#))
            #expect(info.contains(#""OSType":"linux""#))
        }
    }

    @Test("a body over the limit is refused with 413 and the next request is still served")
    func bodyLimit() async throws {
        let harness = try await Harness.start(limits: .init(maxBodyBytes: 16)) {
            $0.add(.POST, "/echo") { request, _ in .text(String(buffer: request.body)) }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            let big = String(repeating: "x", count: 64)
            try await client.send("POST /echo HTTP/1.1\r\nHost: d\r\nContent-Length: 64\r\n\r\n\(big)")
            #expect(try await client.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 413"))
            _ = try await client.read(through: "}")
            // Control: a body within the limit is read whole.
            try await client.send("POST /echo HTTP/1.1\r\nHost: d\r\nContent-Length: 5\r\n\r\nhello")
            #expect(try await client.read(through: "hello").hasPrefix("HTTP/1.1 200"))
        }
    }

    @Test("a stream's head arrives before its first chunk, which is what keeps docker run from waiting forever")
    func streamHeadFirst() async throws {
        let gate = Gate()
        let harness = try await Harness.start {
            $0.add(.POST, "/containers/{id}/wait") { _, _ in
                .stream(status: .ok, contentType: "application/json") { writer in
                    await gate.wait()
                    try await writer.writeJSON(["StatusCode": 3])
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/containers/web/wait?condition=next-exit HTTP/1.1\r\nHost: d\r\n\r\n")
            // Only the head can have arrived: the body is still held behind the gate.
            let head = try await client.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 200"))
            #expect(head.lowercased().contains("transfer-encoding: chunked"))
            await gate.open()
            #expect(try await client.read(through: "0\r\n\r\n").contains(#"{"StatusCode":3}"#))
        }
    }

    @Test("stdin sent with the upgrade request reaches the hijacked stream, and the client's half-close ends its input")
    func hijackKeepsEarlyBytes() async throws {
        let harness = try await Harness.start {
            $0.add(.POST, "/exec/{id}/start") { request, _ in
                let options = String(buffer: request.body)
                return .hijack(multiplexed: false) { stream in
                    try await stream.write(ByteBuffer(string: "body=\(options);"))
                    var input = ""
                    for try await chunk in stream.inbound {
                        input += String(buffer: chunk)
                    }
                    // Input ended with the client's half-close; output still flows back.
                    try await stream.write(ByteBuffer(string: "stdin=\(input);bye"))
                    stream.finishWriting()
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            let body = #"{"Detach":false,"Tty":true}"#
            // One write: the request, its body, and stdin typed before the 101 came back.
            try await client.send(
                "POST /v1.48/exec/e1/start HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)early "
            )
            let upgraded = try await client.read(through: "\r\n\r\n")
            #expect(upgraded.hasPrefix("HTTP/1.1 101 UPGRADED"))
            #expect(upgraded.contains("application/vnd.docker.raw-stream"))
            #expect(try await client.read(through: ";") == #"body={"Detach":false,"Tty":true};"#)
            try await client.send("late")
            client.closeWrite()
            let rest = try await client.readToEnd()
            #expect(rest == "stdin=early late;bye")
        }
    }

    @Test("stdin sent with the upgrade request arrives on its own, without waiting for more input")
    func earlyBytesAlone() async throws {
        let harness = try await Harness.start {
            $0.add(.POST, "/containers/{id}/attach") { _, _ in
                // A route that takes a moment, as a real one does, and a body that reads later.
                try await Task.sleep(for: .milliseconds(50))
                return .hijack(multiplexed: false) { stream in
                    try await Task.sleep(for: .milliseconds(100))
                    var iterator = stream.inbound.makeAsyncIterator()
                    while let chunk = try await iterator.next() {
                        try await stream.write(ByteBuffer(string: "[\(String(buffer: chunk))]"))
                    }
                    stream.finishWriting()
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/containers/web/attach?stream=1&stdin=1 HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nearly")
            _ = try await client.read(through: "\r\n\r\n")
            // Nothing else is sent until the early bytes have come back on their own.
            #expect(try await client.read(through: "]") == "[early]")
            // Control: bytes sent after the upgrade arrive the same way.
            try await client.send("late")
            #expect(try await client.read(through: "]") == "[late]")
        }
    }

    @Test("a stream route asked without Upgrade answers 200 and ends the body by closing, as dockerd does; with Upgrade, 101")
    func hijackWithoutUpgrade() async throws {
        let harness = try await Harness.start {
            $0.add(.POST, "/exec/{id}/start") { _, _ in
                .hijack(multiplexed: true) { stream in
                    try await stream.write(ByteBuffer(string: "o"), stream: .stdout)
                    stream.finishWriting()
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        let body = #"{"Detach":false,"Tty":false}"#
        try await harness.withClient { client in
            // docker-java's exec start without stdin: no Upgrade header.
            try await client.send(
                "POST /exec/e1/start HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            let head = try await client.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(head.contains("Content-Type: application/vnd.docker.multiplexed-stream"))
            #expect(!head.lowercased().contains("content-length") && !head.lowercased().contains("transfer-encoding"))
            #expect(Array(try await client.readToEnd().utf8) == [1, 0, 0, 0, 0, 0, 0, 1, UInt8(ascii: "o")])
        }
        // Control: the same request asking to upgrade is upgraded.
        try await harness.withClient { client in
            try await client.send(
                "POST /exec/e1/start HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            )
            #expect(try await client.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 101 UPGRADED\r\n"))
            #expect(Array(try await client.readToEnd().utf8) == [1, 0, 0, 0, 0, 0, 0, 1, UInt8(ascii: "o")])
        }
    }

    @Test("without a tty the hijacked output is framed")
    func hijackMultiplexed() async throws {
        let harness = try await Harness.start {
            $0.add(.POST, "/containers/{id}/attach") { _, _ in
                .hijack(multiplexed: true) { stream in
                    try await stream.write(ByteBuffer(string: "o"), stream: .stdout)
                    try await stream.write(ByteBuffer(string: "e"), stream: .stderr)
                    stream.finishWriting()
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("POST /containers/web/attach?stream=1&stdout=1&stderr=1 HTTP/1.1\r\nHost: d\r\nUpgrade: tcp\r\nConnection: Upgrade\r\n\r\n")
            let upgraded = try await client.read(through: "\r\n\r\n")
            #expect(upgraded.contains("application/vnd.docker.multiplexed-stream"))
            let framed = Array(try await client.readToEnd().utf8)
            #expect(framed == [1, 0, 0, 0, 0, 0, 0, 1, UInt8(ascii: "o"), 2, 0, 0, 0, 0, 0, 0, 1, UInt8(ascii: "e")])
        }
    }

    @Test("a client that leaves stops what its request was waiting on")
    func disconnectCancels() async throws {
        let cancelled = Gate()
        let harness = try await Harness.start {
            $0.add(.POST, "/containers/{id}/wait") { _, _ in
                .stream(status: .ok, contentType: "application/json") { _ in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        await cancelled.open()
                    }
                }
            }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("POST /containers/web/wait HTTP/1.1\r\nHost: d\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
        }
        // The connection closed when the block returned.
        await cancelled.wait()
    }

    @Test("pipelined requests are answered in the order they were sent")
    func pipelining() async throws {
        let harness = try await Harness.start {
            $0.add(.GET, "/slow") { _, _ in
                try await Task.sleep(for: .milliseconds(200))
                return .text("first")
            }
            $0.add(.GET, "/fast") { _, _ in .text("second") }
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("GET /slow HTTP/1.1\r\nHost: d\r\n\r\nGET /fast HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            let all = try await client.readToEnd()
            let first = try #require(all.range(of: "first"))
            let second = try #require(all.range(of: "second"))
            #expect(first.lowerBound < second.lowerBound)
        }
    }

    @Test("a connection from another user is closed unread, and this user's is served")
    func peerCredentials() async throws {
        let refusing = try await Harness.start(allowedUID: getuid() &+ 1) { SystemRoutes.register(on: &$0, engine: Self.fakeEngine) }
        defer { Task { try? await refusing.stop() } }
        try await refusing.withClient { client in
            // Connection: close, so a server that wrongly answers ends the read at once.
            try? await client.send("GET /_ping HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            #expect(((try? await client.readToEnd()) ?? "") == "")
        }
        // Control: the same server for this user answers.
        let serving = try await Harness.start(allowedUID: getuid()) { SystemRoutes.register(on: &$0, engine: Self.fakeEngine) }
        defer { Task { try? await serving.stop() } }
        try await serving.withClient { client in
            try await client.send("GET /_ping HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            #expect(try await client.readToEnd().hasSuffix("OK"))
        }
    }

    @Test("a malformed request gets a 400 and the connection closes")
    func malformed() async throws {
        let harness = try await Harness.start { SystemRoutes.register(on: &$0, engine: Self.fakeEngine) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("NOT HTTP AT ALL\r\n\r\n")
            let answer = try await client.readToEnd()
            #expect(answer.hasPrefix("HTTP/1.1 400"))
            #expect(answer.contains(#"{"message":"malformed request"}"#))
        }
    }
}

/// Opens once; everyone waiting, before or after, goes through.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
