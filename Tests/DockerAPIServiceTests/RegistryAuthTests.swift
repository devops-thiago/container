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
import Synchronization
import Testing

@testable import DockerAPIService

/// A log that keeps every line, metadata included, at every level.
final class CapturedLog: Sendable {
    private let lines = Mutex<[String]>([])

    var text: String { lines.withLock { $0.joined(separator: "\n") } }

    var logger: Logger {
        var logger = Logger(label: "captured") { _ in Handler(log: self) }
        logger.logLevel = .trace
        return logger
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    struct Handler: LogHandler {
        let log: CapturedLog
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let all = metadata.merging(event.metadata ?? [:]) { _, new in new }
            let fields = all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            log.append("\(event.level) \(event.message) \(fields) \(event.error.map { "error=\($0)" } ?? "")")
        }
    }
}

/// The engine's registry check, answered as the test says, recording what it was asked.
final class FakeRegistryLogin: EngineRegistryLogin {
    let answer: DockerLoginCheck
    let asked = Mutex<[(host: String, scheme: String, credential: DockerRegistryCredential)]>([])

    init(_ answer: DockerLoginCheck) {
        self.answer = answer
    }

    func checkLogin(host: String, scheme: String, credential: DockerRegistryCredential) async throws -> DockerLoginCheck {
        asked.withLock { $0.append((host, scheme, credential)) }
        return answer
    }
}

/// `X-Registry-Auth` as the Docker CLI encodes it, passed to pulls and pushes for that request
/// alone, and `POST /auth` as a check that keeps nothing; neither ever reaches a log.
@Suite(.timeLimit(.minutes(1)))
struct RegistryAuthTests {
    typealias Harness = DockerAPIServerTests.Harness

    static let json = #"{"username":"m229user","password":"s3cret-pw","serveraddress":"localhost:5000"}"#

    static func base64url(_ text: String, padded: Bool = false) -> String {
        var encoded = Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        if !padded { encoded = encoded.replacingOccurrences(of: "=", with: "") }
        return encoded
    }

    @Test("the header decodes from base64url or standard base64, padded or not, with Go's case-blind field names")
    func decodes() throws {
        let expected = DockerRegistryCredential(username: "m229user", secret: "s3cret-pw", serverAddress: "localhost:5000")
        // Characters whose base64 has `/` and `+`, so the two alphabets differ.
        let tricky = #"{"username":"m229user","password":"s3cret-pw","serveraddress":"localhost:5000","x":"?>?>~~"}"#
        for header in [
            Self.base64url(Self.json), Self.base64url(Self.json, padded: true), Data(Self.json.utf8).base64EncodedString(),
            Self.base64url(tricky), Data(tricky.utf8).base64EncodedString(),
        ] {
            #expect(DockerRegistryAuth.credential(header: header) == expected, "\(header)")
        }
        let upper = #"{"Username":"m229user","Password":"s3cret-pw","ServerAddress":"localhost:5000"}"#
        #expect(DockerRegistryAuth.credential(header: Self.base64url(upper)) == expected)
    }

    @Test("an identity token stands in for the password; a registry token alone is not a credential")
    func tokens() {
        let identity = DockerRegistryAuth.credential(header: Self.base64url(#"{"identitytoken":"tok-1","serveraddress":"ghcr.io"}"#))
        #expect(identity == DockerRegistryCredential(username: "<token>", secret: "tok-1", serverAddress: "ghcr.io"))
        let named = DockerRegistryAuth.credential(header: Self.base64url(#"{"username":"ana","identitytoken":"tok-1"}"#))
        #expect(named?.username == "ana")
        #expect(named?.secret == "tok-1")
        // A password wins over a token.
        #expect(DockerRegistryAuth.credential(header: Self.base64url(#"{"username":"ana","password":"pw","identitytoken":"tok"}"#))?.secret == "pw")
        #expect(DockerRegistryAuth.credential(header: Self.base64url(#"{"registrytoken":"bearer-1"}"#)) == nil)
    }

    @Test("an empty, empty-object, anonymous or malformed header is no credential")
    func absent() {
        for header in [
            nil, "", "e30", "e30=", Self.base64url(#"{"serveraddress":"https://index.docker.io/v1/"}"#), "%%%not-base64%%%", Self.base64url("not json"),
            Self.base64url(#"["ana","pw"]"#), "a",
        ] {
            #expect(DockerRegistryAuth.credential(header: header) == nil, "\(header ?? "nil")")
        }
        // Control: the same address with a login is one.
        #expect(DockerRegistryAuth.credential(header: Self.base64url(#"{"username":"a","password":"b","serveraddress":"x"}"#)) != nil)
    }

    @Test(
        "a login names its registry as dockerd reads the address",
        arguments: [
            ("https://index.docker.io/v1/", "docker.io", "https"),
            ("", "docker.io", "https"),
            ("docker.io", "docker.io", "https"),
            ("localhost:5000", "localhost:5000", "https"),
            ("http://localhost:5000", "localhost:5000", "http"),
            ("https://ghcr.io/v2/", "ghcr.io", "https"),
            ("HTTP://127.0.0.1:5000/", "127.0.0.1:5000", "http"),
        ])
    func registry(address: String, host: String, scheme: String) {
        let parsed = DockerRegistryAuth.registry(address)
        #expect(parsed.host == host)
        #expect(parsed.scheme == scheme)
    }

    @Test("printing a credential shows none of it")
    func redacted() {
        let credential = DockerRegistryCredential(username: "ana-user", secret: "s3cret-pw", serverAddress: "localhost:5000")
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(reflecting: credential), dumped, "\([credential])"] {
            #expect(!text.contains("s3cret-pw"), "\(text)")
            #expect(!text.contains("ana-user"), "\(text)")
        }
    }

    // MARK: pull and push

    @Test("a pull hands the header's credential to the engine for that pull, and none without it")
    func pullPassesTheCredential() async throws {
        let images = FakeImageStore()
        let harness = try await Harness.start { ImageRoutes.register(on: &$0, engine: images, progressInterval: .milliseconds(1)) }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send(
                "POST /v1.48/images/create?fromImage=alpine&tag=3.22 HTTP/1.1\r\nHost: d\r\nX-Registry-Auth: \(Self.base64url(Self.json))\r\nConnection: close\r\n\r\n"
            )
            #expect(try await client.readToEnd().contains("Pull complete"))
        }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/images/create?fromImage=alpine&tag=3.22 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.readToEnd()
        }
        #expect(images.credentials == [DockerRegistryCredential(username: "m229user", secret: "s3cret-pw", serverAddress: "localhost:5000"), nil])
    }

    @Test("a push hands the header's credential to the engine for that push, and none without it")
    func pushPassesTheCredential() async throws {
        let routes = try ImageRoutesTests()
        let harness = try await Harness.start {
            ImageRoutes.register(
                on: &$0, engine: routes.images, containers: routes.engine, identities: routes.identities, scratch: routes.scratch,
                progressInterval: .milliseconds(1))
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send(
                "POST /v1.48/images/alpine/push?tag=3.22 HTTP/1.1\r\nHost: d\r\nX-Registry-Auth: \(Self.base64url(Self.json))\r\nConnection: close\r\n\r\n")
            #expect(try await client.readToEnd().contains("Pushed"))
        }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/images/alpine/push?tag=3.22 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.readToEnd()
        }
        #expect(routes.images.credentials == [DockerRegistryCredential(username: "m229user", secret: "s3cret-pw", serverAddress: "localhost:5000"), nil])
    }

    // MARK: /auth

    func auth(_ engine: FakeRegistryLogin, body: String) async throws -> (HTTPResponseStatus, String) {
        var router = DockerRouter()
        AuthRoutes.register(on: &router, engine: engine)
        let request = try DockerRequest(method: .POST, uri: "/v1.48/auth", headers: [:], body: ByteBuffer(string: body))
        guard case .data(let status, _, let buffer, _) = await router.respond(to: request) else {
            Issue.record("expected a whole response")
            return (.internalServerError, "")
        }
        return (status, String(buffer: buffer))
    }

    @Test("a login the registry takes is dockerd's answer, checked where the address says")
    func loginSucceeds() async throws {
        let engine = FakeRegistryLogin(.accepted)
        let (status, body) = try await auth(engine, body: #"{"username":"ana","password":"s3cret-pw","serveraddress":"https://index.docker.io/v1/"}"#)
        #expect(status == .ok)
        let answer = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(answer == ["Status": "Login Succeeded", "IdentityToken": ""])
        let asked = engine.asked.withLock { $0 }
        #expect(asked.map(\.host) == ["docker.io"])
        #expect(asked.map(\.scheme) == ["https"])
        #expect(asked.first?.credential.secret == "s3cret-pw")
    }

    @Test("a login the registry refuses is a 401 in dockerd's words", arguments: [401, 403])
    func loginRefused(status: Int) async throws {
        let (answered, body) = try await auth(FakeRegistryLogin(.rejected(status: status)), body: Self.json)
        #expect(answered == .unauthorized)
        let reason = status == 401 ? "Unauthorized" : "Forbidden"
        #expect(body == #"{"message":"login attempt to https://localhost:5000/v2/ failed with status: \#(status) \#(reason)"}"#)
        #expect(!body.contains("s3cret-pw"))
    }

    @Test("a body that is not an AuthConfig is refused before the registry is asked")
    func loginBadBody() async throws {
        let engine = FakeRegistryLogin(.accepted)
        for body in ["", "not json", "[1,2]"] {
            let (status, answer) = try await auth(engine, body: body)
            #expect(status == .badRequest, "\(body)")
            #expect(!answer.contains("not json"))
        }
        #expect(engine.asked.withLock { $0.isEmpty })
    }

    // MARK: logs

    /// What must never be in a log: the header as sent, and what it decodes to.
    static let secrets = [base64url(json), "s3cret-pw", "m229user"]

    static func leaks(_ log: String) -> [String] {
        secrets.filter { log.contains($0) }
    }

    @Test("neither /auth nor a pull's X-Registry-Auth reaches the log, over the socket or the router")
    func nothingLogged() async throws {
        let captured = CapturedLog()
        let images = FakeImageStore()
        let harness = try await Harness.start(log: captured.logger) {
            ImageRoutes.register(on: &$0, engine: images, progressInterval: .milliseconds(1))
            AuthRoutes.register(on: &$0, engine: FakeRegistryLogin(.rejected(status: 401)))
        }
        defer { Task { try? await harness.stop() } }
        let header = "X-Registry-Auth: \(Self.base64url(Self.json))\r\n"
        try await harness.withClient { client in
            // Refused before the head (a bad platform), so the router logs the failure.
            try await client.send("POST /v1.48/images/create?fromImage=alpine&platform=x HTTP/1.1\r\nHost: d\r\n\(header)Connection: close\r\n\r\n")
            #expect(try await client.readToEnd().contains("400 Bad Request"))
        }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/images/create?fromImage=alpine HTTP/1.1\r\nHost: d\r\n\(header)Connection: close\r\n\r\n")
            _ = try await client.readToEnd()
        }
        try await harness.withClient { client in
            try await client.send(
                "POST /v1.48/auth HTTP/1.1\r\nHost: d\r\n\(header)Content-Type: application/json\r\nContent-Length: \(Self.json.utf8.count)\r\nConnection: close\r\n\r\n\(Self.json)"
            )
            #expect(try await client.readToEnd().contains("401 Unauthorized"))
        }

        // Through the router alone, too.
        var router = DockerRouter(log: captured.logger)
        AuthRoutes.register(on: &router, engine: FakeRegistryLogin(.rejected(status: 401)))
        _ = await router.respond(
            to: try DockerRequest(
                method: .POST, uri: "/auth", headers: ["X-Registry-Auth": Self.base64url(Self.json)], body: ByteBuffer(string: Self.json)))

        let log = captured.text
        #expect(Self.leaks(log).isEmpty, "the log holds a credential:\n\(log)")
        // Positive control: the requests were logged, by method and path.
        #expect(log.contains("path=/auth"), "\(log)")
        #expect(log.contains("path=/images/create"), "\(log)")
    }

    @Test("the leak check catches a route that does log the header")
    func leakCheckCatchesALeak() async throws {
        let captured = CapturedLog()
        let log = captured.logger
        var router = DockerRouter(log: log)
        router.add(.POST, "/leaky") { request, _ in
            log.debug("leaky", metadata: ["auth": "\(request.headers.first(name: DockerRegistryAuth.header) ?? "")"])
            return .empty()
        }
        _ = await router.respond(
            to: try DockerRequest(method: .POST, uri: "/leaky", headers: ["X-Registry-Auth": Self.base64url(Self.json)], body: ByteBuffer()))
        #expect(Self.leaks(captured.text) == [Self.base64url(Self.json)])
    }
}
