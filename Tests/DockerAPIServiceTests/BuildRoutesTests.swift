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

import Compression
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Synchronization
import Testing
import zlib

@testable import DockerAPIService

/// The builder in memory: what each build was asked, what its context held while it ran, and
/// the output it writes, in pieces that do not end at lines. A build that succeeds tags the
/// fake image store, so the route finds the image's ID there.
final class FakeBuilder: EngineBuilder, Sendable {
    struct State {
        var requests: [DockerBuildRequest] = []
        /// Each build's context while it ran: relative path to contents ("->target" for a link).
        var contexts: [[String: String]] = []
        var output: [String] = ["#1 [internal] load build definition from Dockerfile\n#1 DONE", " 0.0s\n", "#2 [1/2] FROM alpine:3.22"]
        var failure: DockerAPIError?
        /// Hold the build after its output until it is cancelled.
        var hold = false
        /// Whether a held build saw its context still there when it was cancelled.
        var contextAtCancel: Bool?
        /// The ID, and index digest, of the image the next build makes.
        var imageID: Character = FakeBuilder.imageID
    }

    static let imageID: Character = "f"

    let state = Mutex(State())
    let images: FakeImageStore

    init(images: FakeImageStore) {
        self.images = images
    }

    var requests: [DockerBuildRequest] { state.withLock { $0.requests } }
    var contexts: [[String: String]] { state.withLock { $0.contexts } }

    func build(_ request: DockerBuildRequest, output: @escaping @Sendable (Data) async -> Void) async throws {
        let files = try Self.files(in: request.context)
        let (chunks, failure) = state.withLock { state in
            state.requests.append(request)
            state.contexts.append(files)
            return (state.output, state.failure)
        }
        for chunk in chunks { await output(Data(chunk.utf8)) }
        if state.withLock({ $0.hold }) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                let present = FileManager.default.fileExists(atPath: request.context.path(percentEncoded: false))
                state.withLock { $0.contextAtCancel = present }
                throw error
            }
        }
        if let failure { throw failure }
        let id = state.withLock { $0.imageID }
        images.state.withLock { state in
            for tag in request.tags { state.records.append(StoreFixtures.record(tag, id: id)) }
        }
    }

    static func files(in root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let rootPath = root.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(atPath: rootPath) else { return [:] }
        while let relative = walker.nextObject() as? String {
            let path = rootPath + "/" + relative
            var isDirectory: ObjCBool = false
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                files[relative] = "->" + target
            } else if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                files[relative] = ""
            } else if let data = FileManager.default.contents(atPath: path) {
                files[relative] = String(decoding: data, as: UTF8.self)
            }
        }
        return files
    }
}

/// Bodies as the Docker CLI sends them.
enum BuildBodies {
    enum Entry {
        case file(String, String)
        case directory(String)
        case symlink(String, String)
    }

    static func tar(_ entries: [Entry]) -> [UInt8] {
        var out: [UInt8] = []
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for entry in entries {
            switch entry {
            case .file(let name, let content):
                let bytes = Array(content.utf8)
                out += DockerTar.header(.init(name: name, type: .file, mode: 0o644, size: UInt64(bytes.count), mtime: now))
                out += bytes + DockerTar.padding(bytes.count)
            case .directory(let name):
                out += DockerTar.header(.init(name: name + "/", type: .directory, mode: 0o755, mtime: now))
            case .symlink(let name, let target):
                out += DockerTar.header(.init(name: name, type: .symlink, mode: 0o777, mtime: now, linkTarget: target))
            }
        }
        return out + DockerTar.end
    }

    static func tar(_ files: [(String, String)]) -> [UInt8] {
        tar(files.map { .file($0.0, $0.1) })
    }

    /// gzip, as `docker build --compress` sends it.
    static func gzip(_ bytes: [UInt8]) -> [UInt8] {
        var stream = z_stream()
        // 15 window bits, plus 16 for a gzip wrapper.
        precondition(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var input = bytes
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(bytes.count))) + 64)
        let count = input.withUnsafeMutableBufferPointer { inputBuffer in
            out.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                precondition(deflate(&stream, Z_FINISH) == Z_STREAM_END)
                return outputBuffer.count - Int(stream.avail_out)
            }
        }
        return Array(out[..<count])
    }

    /// xz, through the system's LZMA encoder.
    static func xz(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count + 4096)
        let count = compression_encode_buffer(&out, out.count, bytes, bytes.count, nil, COMPRESSION_LZMA)
        precondition(count > 0)
        return Array(out[..<count])
    }

    /// `printf 'FROM scratch\nCOPY hello /hello\n' | xz`, from xz 5 (CRC64 check), and the same
    /// through `bzip2`.
    static let xzFromTheCLI = Array(
        Data(base64Encoded: "/Td6WFoAAATm1rRGBMAjHyEBFgAAAAAAAAAAAAAbLvYBAB5GUk9NIHNjcmF0Y2gKQ09QWSBoZWxsbyAvaGVsbG8KAAAistm/QflfVgABPx/iklD1H7bzfQEAAAAABFla")!)
    static let bzip2FromTheCLI = Array(
        Data(base64Encoded: "QlpoOTFBWSZTWTWNwDYAAAPXgAAQQACJAtAgKkScACAAIagaGmmjT1CmTEyDIx+hsogVlppoJcR3fgQLVPxdyRThQkDWNwDY")!)
    static let gzipFromTheCLI = Array(Data(base64Encoded: "H4sICC8Q0moAA2Z4LnR4dABzC/L3VShOLkosSc7gcvYPiFTISM3JyVfQB1NcAOCjyYkfAAAA")!)
    static let fixtureText = "FROM scratch\nCOPY hello /hello\n"

    static let context: [(String, String)] = [("Dockerfile", "FROM alpine:3.22\nCOPY hello /hello\n"), ("hello", "hi\n")]
}

@Suite(.timeLimit(.minutes(1)))
struct BuildRoutesTests {
    typealias B = BuildBodies

    let scratch: URL
    let images = FakeImageStore()
    let builder: FakeBuilder

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "dapi-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        builder = FakeBuilder(images: images)
    }

    func router(limits: DockerBuildLimits = .init()) -> DockerRouter {
        var router = DockerRouter()
        BuildRoutes.register(on: &router, builder: builder, images: images, scratch: scratch, limits: limits)
        return router
    }

    func scratchEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))
    }

    /// Prepares `body` the way the route does, in a directory of its own.
    func prepare(_ body: [UInt8], dockerfile: String = "Dockerfile", limits: DockerBuildLimits = .init()) throws -> DockerBuildContext {
        let directory = scratch.appending(path: "prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "body")
        try Data(body).write(to: file)
        return try DockerBuildContext.prepare(body: file, dockerfile: dockerfile, in: directory, limits: limits)
    }

    func refusal(_ body: [UInt8], dockerfile: String = "Dockerfile", limits: DockerBuildLimits = .init()) -> DockerAPIError? {
        do {
            _ = try prepare(body, dockerfile: dockerfile, limits: limits)
            return nil
        } catch let error as DockerAPIError {
            return error
        } catch {
            return DockerAPIError.internalError("\(error)")
        }
    }

    // MARK: - Parameters

    func parameters(_ query: String) throws(DockerAPIError) -> BuildRoutes.Parameters {
        try BuildRoutes.Parameters(try DockerRequest(method: .POST, uri: "/v1.48/build?" + query, headers: [:], body: ByteBuffer()))
    }

    @Test("parameters decode as dockerd reads them: repeated t, URI-encoded JSON maps, booleans and platform")
    func parameterDecoding() throws {
        let buildargs = #"{"B":"two words","A":"1","UNSET":null}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let labels = #"{"org.example":"x=y"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let decoded = try parameters(
            "t=m231-web&t=ghcr.io/org/app:2&t=m231-web:latest&dockerfile=.dockerfile.abc123&buildargs=\(buildargs)&labels=\(labels)"
                + "&target=final&nocache=1&pull=true&platform=linux/amd64&q=1&version=1&rm=1&memory=0")
        #expect(decoded.tags.map(\.normalized) == ["docker.io/library/m231-web:latest", "ghcr.io/org/app:2"])
        #expect(decoded.dockerfile == ".dockerfile.abc123")
        // Sorted by key; a null build arg is left out.
        #expect(decoded.buildArgs == ["A=1", "B=two words"])
        #expect(decoded.labels == ["org.example=x=y"])
        #expect(decoded.target == "final")
        #expect(decoded.noCache && decoded.pull && decoded.quiet)
        #expect(decoded.platform == "linux/amd64")

        // Control: nothing given is dockerd's defaults.
        let defaults = try parameters("")
        #expect(defaults == BuildRoutes.Parameters())
        #expect(defaults.dockerfile == "Dockerfile" && defaults.tags.isEmpty && !defaults.quiet && defaults.platform == nil)
    }

    @Test("parameters this builder cannot honour, or that do not parse, are refused before anything is unpacked")
    func parameterRefusals() throws {
        for (query, words) in [
            ("version=2", "DOCKER_BUILDKIT=0"), ("version=3", "invalid version"),
            ("remote=https://github.com/org/repo.git", "remote build context"),
            ("t=UPPER", "invalid reference format"), ("t=web@sha256:" + String(repeating: "a", count: 64), "digest reference"),
            ("buildargs=%5B1%5D", "error reading build args"), ("buildargs=%7B%22A%22%3A1%7D", "not a string"),
            ("labels=nope", "error reading labels"), ("nocache=maybe", "invalid value for nocache"), ("platform=linux", "invalid platform"),
        ] {
            #expect(throws: DockerAPIError.self, "\(query)") { try parameters(query) }
            do {
                _ = try parameters(query)
            } catch {
                #expect(error.status == .badRequest, "\(query)")
                #expect(error.message.contains(words), "\(query): \(error.message)")
            }
        }
    }

    // MARK: - Context

    @Test("a tar, a gzipped tar and an xz tar unpack to the same context")
    func compressedContexts() throws {
        let tar = B.tar([.directory("src"), .file("src/a.txt", "a\n"), .file("Dockerfile", "FROM alpine\n"), .file(".dockerignore", "*.md\n")])
        for body in [tar, B.gzip(tar), B.xz(tar)] {
            let prepared = try prepare(body)
            #expect(try FakeBuilder.files(in: prepared.context) == ["src": "", "src/a.txt": "a\n", "Dockerfile": "FROM alpine\n", ".dockerignore": "*.md\n"])
            #expect(prepared.dockerfile == Data("FROM alpine\n".utf8))
            #expect(prepared.dockerignore == Data("*.md\n".utf8))
            // The decompressed copy does not stay beside the context.
            #expect(!FileManager.default.fileExists(atPath: prepared.context.deletingLastPathComponent().appending(path: "context.tar").path))
        }
    }

    @Test("gzip and xz from the real tools decompress; bzip2 and zstd are refused in words")
    func compressionFormats() throws {
        for (body, encoding) in [(B.gzipFromTheCLI, DockerBuildContext.Encoding.gzip), (B.xzFromTheCLI, .xz)] {
            let file = scratch.appending(path: "in-\(encoding)")
            let out = scratch.appending(path: "out-\(encoding)")
            try Data(body).write(to: file)
            #expect(try DockerBuildContext.encoding(of: file) == encoding)
            try DockerBuildContext.decompress(file, encoding: encoding, to: out, maxBytes: 1 << 20)
            #expect(try String(contentsOf: out, encoding: .utf8) == B.fixtureText)
        }
        // These are bare Dockerfiles once decompressed, which is a context too.
        #expect(try prepare(B.gzipFromTheCLI).dockerfile == Data(B.fixtureText.utf8))
        #expect(try prepare(B.xzFromTheCLI).dockerfile == Data(B.fixtureText.utf8))

        let bzip2 = try #require(refusal(B.bzip2FromTheCLI))
        #expect(bzip2.status == .badRequest)
        #expect(bzip2.message.contains("bzip2-compressed build context is not supported"))
        let zstd = try #require(refusal([0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0]))
        #expect(zstd.message.contains("zstd-compressed"))
        // Control: an uncompressed tar is not mistaken for any of them.
        #expect(refusal(B.tar(B.context)) == nil)
    }

    @Test("a cut-short or corrupt stream, and one that decompresses past the bound, are refused")
    func badStreams() throws {
        let gzipped = B.gzip(B.tar(B.context))
        let truncated = try #require(refusal(Array(gzipped.dropLast(12))))
        #expect(truncated.status == .badRequest)
        #expect(truncated.message.contains("gzip"))
        var corrupt = gzipped
        corrupt[corrupt.count / 2] ^= 0xFF
        #expect(refusal(corrupt)?.message.contains("gzip") == true)
        let xz = B.xz(B.tar(B.context))
        #expect(refusal(Array(xz.dropLast(20)))?.message.contains("xz") == true)

        // A small body that is a great deal of context.
        let bomb = B.gzip([UInt8](repeating: 0, count: 4 << 20))
        let refused = try #require(refusal(bomb, limits: .init(maxContextBytes: 1 << 20)))
        #expect(refused.status == .payloadTooLarge)
        // Control: the same under a larger bound decompresses (all zeros: an empty archive).
        #expect(refusal(bomb, limits: .init(maxContextBytes: 8 << 20))?.message == "Cannot locate specified Dockerfile: Dockerfile")
    }

    @Test("an archive that reaches outside its directory is refused, and nothing is written outside")
    func tarGuard() throws {
        for (entries, words) in [
            ([BuildBodies.Entry.file("../escape", "x")], "leaves it"), ([.file("/abs", "x")], "absolute path"),
            ([.symlink("out", "../../.."), .file("Dockerfile", "FROM a\n")], "points outside"),
            ([.symlink("dir", "/etc"), .file("dir/passwd", "x")], "points outside"),
        ] {
            let refused = try #require(refusal(B.tar(entries)), "\(entries)")
            #expect(refused.status == .badRequest)
            #expect(refused.message.hasPrefix("invalid build context: "), "\(refused.message)")
            #expect(refused.message.contains(words), "\(refused.message)")
        }
        let written = FileManager.default.enumerator(atPath: scratch.path(percentEncoded: false))?.allObjects as? [String] ?? []
        #expect(!written.contains { $0.hasSuffix("escape") || $0.hasSuffix("passwd") }, "\(written)")
        // Control: a link that stays inside is kept, and a Dockerfile reached through it is read.
        let prepared = try prepare(B.tar([.directory("real"), .file("real/Dockerfile", "FROM b\n"), .symlink("Dockerfile", "real/Dockerfile")]))
        #expect(prepared.dockerfile == Data("FROM b\n".utf8))
        #expect(try FakeBuilder.files(in: prepared.context)["Dockerfile"] == "->real/Dockerfile")
    }

    @Test("a body that is not a tar is the Dockerfile itself, with an empty context")
    func bareDockerfile() throws {
        let prepared = try prepare(Array("FROM alpine:3.22\nRUN echo hi > /hi\n".utf8), dockerfile: "Ignored.df")
        #expect(prepared.dockerfile == Data("FROM alpine:3.22\nRUN echo hi > /hi\n".utf8))
        #expect(prepared.dockerfileName == "Dockerfile")
        #expect(try FakeBuilder.files(in: prepared.context).isEmpty)
        // A long one, past a tar block: still not a tar, since its first block has no checksum.
        let long = "FROM alpine\n" + String(repeating: "# comment\n", count: 200)
        #expect(try prepare(Array(long.utf8)).dockerfile.count == long.utf8.count)
        // Control: a real archive is unpacked, not taken as a Dockerfile.
        let archive = try prepare(B.tar(B.context))
        #expect(archive.dockerfile == Data("FROM alpine:3.22\nCOPY hello /hello\n".utf8))
        #expect(try FakeBuilder.files(in: archive.context)["hello"] == "hi\n")
        // An empty body is an empty archive, which has no Dockerfile.
        #expect(refusal([])?.message == "Cannot locate specified Dockerfile: Dockerfile")
    }

    @Test("the Dockerfile is found as dockerd finds it, and refused in dockerd's words when it is not there")
    func dockerfileLookup() throws {
        #expect(try prepare(B.tar([("dockerfile", "FROM lower\n")])).dockerfileName == "dockerfile")
        // The CLI's name for a Dockerfile from outside the context.
        let outside = try prepare(B.tar([(".dockerfile.5f3a9c", "FROM outside\n"), (".dockerignore", ".dockerfile.5f3a9c\n")]), dockerfile: ".dockerfile.5f3a9c")
        #expect(outside.dockerfile == Data("FROM outside\n".utf8))
        #expect(try prepare(B.tar([("build/Containerfile", "FROM nested\n")]), dockerfile: "build/Containerfile").dockerfile == Data("FROM nested\n".utf8))

        #expect(refusal(B.tar([("hello", "hi")]))?.message == "Cannot locate specified Dockerfile: Dockerfile")
        // With dockerd's status, 500; a path outside the context is the client's error, a 400.
        #expect(refusal(B.tar([("hello", "hi")]))?.status == .internalServerError)
        #expect(refusal(B.tar(B.context), dockerfile: "../Dockerfile")?.status == .badRequest)
        // The lowercase fallback is for the default name alone.
        #expect(refusal(B.tar([("dockerfile.dev", "FROM x\n")]), dockerfile: "Dockerfile.dev")?.message == "Cannot locate specified Dockerfile: Dockerfile.dev")
        // A directory is not a Dockerfile.
        #expect(refusal(B.tar([.directory("Dockerfile")]))?.message == "Cannot locate specified Dockerfile: Dockerfile")
        for name in ["../Dockerfile", "/etc/passwd", "a/../../b"] {
            #expect(refusal(B.tar(B.context), dockerfile: name)?.message.contains("must be inside the build context") == true, "\(name)")
        }
    }

    @Test("the 16 KiB Dockerfile limit applies to a context's Dockerfile and to a bare one, in container build's words")
    func dockerfileLimit() throws {
        let under = String(repeating: "#", count: 16 * 1024 - 1)
        #expect(refusal(B.tar([("Dockerfile", under)])) == nil)
        #expect(refusal(Array(under.utf8)) == nil)
        let at = String(repeating: "#", count: 16 * 1024)
        let expected = "Dockerfile size (16384 bytes) exceeds the maximum allowed size of 16384 bytes. See https://github.com/apple/container/issues/735."
        #expect(refusal(B.tar([("Dockerfile", at)])) == .badRequest(expected))
        #expect(refusal(Array(at.utf8)) == .badRequest(expected))
        // A large one is measured, not read.
        let large = String(repeating: "#", count: 3 << 20)
        #expect(refusal(B.tar([("Dockerfile", large)]))?.message.hasPrefix("Dockerfile size (3145728 bytes)") == true)
    }

    // MARK: - The route

    func harness(log: Logger = Logger(label: "DockerAPIService"), limits: DockerBuildLimits = .init()) async throws -> DockerAPIServerTests.Harness {
        let builder = self.builder
        let images = self.images
        let scratch = self.scratch
        return try await DockerAPIServerTests.Harness.start(limits: .init(maxBodyBytes: 1024, spoolDirectory: scratch), log: log) {
            BuildRoutes.register(on: &$0, builder: builder, images: images, scratch: scratch, limits: limits)
        }
    }

    func post(
        _ harness: DockerAPIServerTests.Harness, _ query: String, body: [UInt8], headers: [String] = []
    ) async throws -> (head: String, lines: [[String: Any]], text: String) {
        let extra = headers.map { $0 + "\r\n" }.joined()
        let answer = try await ImageRoutesTests.exchange(
            harness,
            "POST /v1.48/build?\(query) HTTP/1.1\r\nHost: d\r\nContent-Type: application/x-tar\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n",
            body: body)
        let text = String(decoding: answer.body, as: UTF8.self)
        let lines = try answer.body.split(separator: UInt8(ascii: "\n")).map {
            try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:]
        }
        return (answer.head, lines, text)
    }

    /// Files are deleted off the event loop once an answer is sent: waits up to 5 s for it.
    func waitForEmptyScratch() async throws {
        for _ in 0..<500 where !(try scratchEntries().isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static let id = StoreFixtures.digest(FakeBuilder.imageID)

    @Test("a build streams the builder's output as lines, then aux with the image's ID, then the Successfully lines")
    func outputFraming() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        // Spooled: larger than the memory limit.
        let body = B.tar(B.context + [("padding", String(repeating: "p", count: 4000))])
        let answer = try await post(harness, "t=m231-web&t=m231-web:1&buildargs=%7B%22A%22%3A%221%22%7D", body: body)
        #expect(answer.head.hasPrefix("HTTP/1.1 200"))
        let lines = answer.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 7)
        #expect(
            Array(lines.prefix(3)) == [
                ##"{"stream":"#1 [internal] load build definition from Dockerfile\n"}"##, ##"{"stream":"#1 DONE 0.0s\n"}"##,
                // The last piece had no newline; it ends its line.
                ##"{"stream":"#2 [1/2] FROM alpine:3.22\n"}"##,
            ])
        // dockerd's aux record, which the CLI reads the ID from.
        #expect(answer.lines[3]["id"] as? String == "moby.image.id")
        #expect(answer.lines[3]["aux"] as? [String: String] == ["ID": Self.id])
        #expect(
            Array(lines.suffix(3)) == [
                #"{"stream":"Successfully built ffffffffffff\n"}"#,
                #"{"stream":"Successfully tagged m231-web:latest\n"}"#, #"{"stream":"Successfully tagged m231-web:1\n"}"#,
            ])
        let request = try #require(builder.requests.first)
        #expect(request.tags == ["docker.io/library/m231-web:latest", "docker.io/library/m231-web:1"])
        #expect(request.buildArgs == ["A=1"])
        #expect(request.dockerfile == Data("FROM alpine:3.22\nCOPY hello /hello\n".utf8))
        #expect(builder.contexts.first?["hello"] == "hi\n")
        // The aux ID is the one the image routes give the image.
        #expect(try DockerImageCatalog(try await images.list()).resolve("m231-web:1").image.id == Self.id)
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
    }

    func imageRouter() -> DockerRouter {
        var router = DockerRouter()
        ImageRoutes.register(on: &router, engine: images, containers: FakeEngine(), identities: DockerIdentityStore(persistence: nil), scratch: scratch)
        return router
    }

    func imageCall(_ method: HTTPMethod, _ uri: String) async throws -> Any {
        let request = try DockerRequest(method: method, uri: "/v1.48" + uri, headers: [:], body: ByteBuffer())
        guard case .data(let status, _, let body, _) = await imageRouter().respond(to: request) else {
            Issue.record("expected a whole response")
            return [:]
        }
        #expect(status == .ok, "\(uri)")
        return try JSONSerialization.jsonObject(with: Data(String(buffer: body).utf8))
    }

    static let danglingFilter = "/images/json?filters=" + #"{"dangling":["true"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    @Test("without a name the image is dangling, as Docker 29 keeps one: moby-dangling@<digest>, <none>:<none>, pruned by a plain prune")
    func untagged() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        let answer = try await post(harness, "", body: B.tar(B.context))
        #expect(answer.lines.contains { ($0["aux"] as? [String: Any])?["ID"] as? String == Self.id })
        #expect(!answer.text.contains("Successfully tagged"))
        #expect(answer.text.contains("Successfully built ffffffffffff"))
        // Built under a reserved tag of its own, which is then replaced by the digest form.
        let tag = try #require(builder.requests.first?.tags.first)
        #expect(tag.wholeMatch(of: #/docker\.io/library/moby-dangling:build-[0-9a-f]{32}/#) != nil, "\(tag)")
        #expect(images.references == ["docker.io/library/moby-dangling@" + Self.id])

        // Listed by dangling=true as <none>:<none>: no repo tags, no repo digests.
        let dangling = try #require(try await imageCall(.GET, Self.danglingFilter) as? [[String: Any]])
        #expect(dangling.map { $0["Id"] as? String } == [Self.id])
        #expect((dangling.first?["RepoTags"] as? [String])?.isEmpty == true)
        #expect((dangling.first?["RepoDigests"] as? [String])?.isEmpty == true)
        let inspect = try #require(try await imageCall(.GET, "/images/\(Self.id)/json") as? [String: Any])
        #expect((inspect["RepoTags"] as? [String])?.isEmpty == true)
        #expect((inspect["RepoDigests"] as? [String])?.isEmpty == true)

        // Control: a tagged build is not dangling, and neither is an image in a repository
        // whose name only starts with the reserved one.
        builder.state.withLock { $0.imageID = "e" }
        _ = try await post(harness, "t=m231-named", body: B.tar(B.context))
        images.state.withLock { $0.records.append(StoreFixtures.record("docker.io/library/moby-dangling-foo:1", id: "d")) }
        let all = try #require(try await imageCall(.GET, "/images/json") as? [[String: Any]])
        let tags = Dictionary(uniqueKeysWithValues: all.map { ($0["Id"] as? String ?? "", $0["RepoTags"] as? [String] ?? []) })
        #expect(tags[StoreFixtures.digest("e")] == ["m231-named:latest"])
        #expect(tags[StoreFixtures.digest("d")] == ["moby-dangling-foo:1"])
        #expect(try #require(try await imageCall(.GET, Self.danglingFilter) as? [[String: Any]]).count == 1)

        // A plain prune removes it, reported by its ID alone, and leaves the named ones.
        let pruned = try #require(try await imageCall(.POST, "/images/prune") as? [String: Any])
        let items = try #require(pruned["ImagesDeleted"] as? [[String: String]])
        #expect(items == [["Deleted": Self.id]])
        #expect(images.references == ["docker.io/library/m231-named:latest", "docker.io/library/moby-dangling-foo:1"])
    }

    @Test("naming a dangling image drops its reserved reference; deleting its last name deletes it")
    func danglingThenNamed() async throws {
        images.state.withLock { $0.records.append(StoreFixtures.record("docker.io/library/moby-dangling@" + Self.id, id: FakeBuilder.imageID)) }
        let catalog = DockerImageCatalog(try await images.list())
        #expect(catalog.images.first?.isDangling == true)
        // Control: a digest reference in any other repository names the image.
        let pinned = DockerImageCatalog([StoreFixtures.record("docker.io/library/alpine@" + Self.id, id: FakeBuilder.imageID)])
        #expect(pinned.images.first?.isDangling == false)
        #expect(pinned.images.first?.repoDigests == ["alpine@" + Self.id])

        let request = try DockerRequest(method: .POST, uri: "/v1.48/images/\(Self.id)/tag?repo=m231-later&tag=1", headers: [:], body: ByteBuffer())
        guard case .data(let status, _, _, _) = await imageRouter().respond(to: request) else {
            Issue.record("expected a whole response")
            return
        }
        #expect(status == .created)
        #expect(images.references == ["docker.io/library/m231-later:1"])
        #expect(try #require(try await imageCall(.GET, Self.danglingFilter) as? [[String: Any]]).isEmpty)

        // With the reserved reference back beside a name, deleting the name deletes the image.
        images.state.withLock { $0.records.append(StoreFixtures.record("docker.io/library/moby-dangling@" + Self.id, id: FakeBuilder.imageID)) }
        let deleted = try #require(try await imageCall(.DELETE, "/images/m231-later:1") as? [[String: String]])
        #expect(deleted == [["Untagged": "m231-later:1"], ["Deleted": Self.id]])
        #expect(images.references.isEmpty)
    }

    @Test("q=1 sends the ID alone; a failed quiet build sends what it held back, then the error")
    func quiet() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        let quiet = try await post(harness, "t=m231-q&q=1", body: B.tar(B.context))
        #expect(quiet.text == #"{"stream":"\#(Self.id)\n"}"# + "\n")

        builder.state.withLock { $0.failure = DockerAPIError.internalError("process \"/bin/sh -c false\" did not complete successfully: exit code: 1") }
        let failed = try await post(harness, "t=m231-q&q=1", body: B.tar(B.context))
        #expect(failed.head.hasPrefix("HTTP/1.1 200"))
        #expect(failed.lines.count == 4)
        #expect(failed.lines.first?["stream"] as? String == "#1 [internal] load build definition from Dockerfile\n")
        let last = try #require(failed.lines.last)
        #expect((last["errorDetail"] as? [String: Any])?["message"] as? String == "process \"/bin/sh -c false\" did not complete successfully: exit code: 1")
        #expect(last["error"] as? String == "process \"/bin/sh -c false\" did not complete successfully: exit code: 1")
    }

    @Test("a failed build ends its stream with errorDetail and sends no aux; the context goes either way")
    func failure() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        builder.state.withLock { $0.failure = DockerAPIError.internalError("boom") }
        let failed = try await post(harness, "t=m231-fail", body: B.tar(B.context))
        #expect(failed.lines.map { $0["stream"] as? String }.compactMap { $0 }.count == 3)
        let last = try #require(failed.lines.last)
        #expect((last["errorDetail"] as? [String: String]) == ["message": "boom"])
        #expect(last["error"] as? String == "boom")
        #expect(failed.lines.count == 4)
        #expect(!failed.text.contains("aux") && !failed.text.contains("Successfully"))
        // The context was there while the build ran, and is gone now.
        #expect(builder.contexts.first?["Dockerfile"] != nil)
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
    }

    @Test("a client that leaves mid-build cancels it, and the context goes once the build has stopped")
    func abandoned() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        builder.state.withLock { $0.hold = true }
        let body = B.tar(B.context)
        try await harness.withClient { client in
            try await client.send(
                "POST /v1.48/build?t=m231-gone HTTP/1.1\r\nHost: d\r\nContent-Length: \(body.count)\r\n\r\n")
            try await client.outbound.write(ByteBuffer(bytes: body))
            // The last piece has no newline, so it is held until the build ends: read to the one before.
            _ = try await client.read(through: "DONE 0.0s")
            // The build is running, with its context.
            #expect(try scratchEntries().contains { $0.hasPrefix("build-") })
            // The client goes: the server sees its end of the connection close, and closes too.
            client.closeWrite()
            _ = try await client.readToEnd()
        }
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
        // Removed after the build stopped, not under it.
        #expect(builder.state.withLock { $0.contextAtCancel } == true)
    }

    @Test("a refusal before the build is a status, not a stream, and leaves nothing behind")
    func refusedBeforeTheHead() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        let missing = try await post(harness, "t=m231-x", body: B.tar([("hello", "hi")]))
        // dockerd's status for it.
        #expect(missing.head.hasPrefix("HTTP/1.1 500"))
        #expect(missing.text == #"{"message":"Cannot locate specified Dockerfile: Dockerfile"}"#)
        let escape = try await post(harness, "t=m231-x", body: B.tar([.file("../x", "x")]))
        #expect(escape.head.hasPrefix("HTTP/1.1 400"))
        let version = try await post(harness, "version=2", body: B.tar(B.context))
        #expect(version.head.hasPrefix("HTTP/1.1 400"))
        #expect(builder.requests.isEmpty)
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
        // Control: the same harness builds a good context.
        #expect(try await post(harness, "t=m231-x", body: B.tar(B.context)).head.hasPrefix("HTTP/1.1 200"))
    }

    @Test("a malformed context is a 400 in words, not a stopped service: the builder is never asked")
    func malformedContext() async throws {
        let harness = try await harness()
        defer { Task { try? await harness.stop() } }
        for (name, archive) in ArchiveRouteTests.malformed {
            let answer = try await post(harness, "t=m231-bad", body: archive)
            #expect(answer.head.hasPrefix("HTTP/1.1 400"), "\(name)")
            #expect(answer.text.hasPrefix(#"{"message":"invalid build context: invalid "#), "\(name): \(answer.text)")
        }
        #expect(builder.requests.isEmpty)
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
        // Control: the same harness builds a good context after them.
        #expect(try await post(harness, "t=m231-ok", body: B.tar(B.context)).head.hasPrefix("HTTP/1.1 200"))
    }

    @Test("a body past the bound is refused while it arrives")
    func bodyBound() async throws {
        let harness = try await harness(limits: .init(maxBodyBytes: 2048))
        defer { Task { try? await harness.stop() } }
        let answer = try await post(harness, "t=m231-big", body: B.tar([("Dockerfile", String(repeating: "#", count: 4096))]))
        #expect(answer.head.hasPrefix("HTTP/1.1 413"))
        #expect(builder.requests.isEmpty)
        try await waitForEmptyScratch()
        #expect(try scratchEntries().isEmpty)
    }

    @Test("X-Registry-Config reaches the builder by registry host and never a log")
    func credentials() async throws {
        let secret = "m231-s3cret-\(UUID().uuidString)"
        let config = #"{"https://index.docker.io/v1/":{"username":"m231user","password":"\#(secret)"},"localhost:5999":{"identitytoken":"\#(secret)-tok"},"ghcr.io":{}}"#
        let header = RegistryAuthTests.base64url(config)
        let log = CapturedLog()
        let harness = try await harness(log: log.logger)
        defer { Task { try? await harness.stop() } }

        let built = try await post(harness, "t=m231-cred", body: B.tar(B.context), headers: ["X-Registry-Config: \(header)"])
        #expect(built.head.hasPrefix("HTTP/1.1 200"))
        builder.state.withLock { $0.failure = DockerAPIError.internalError("pull failed") }
        _ = try await post(harness, "t=m231-cred", body: B.tar(B.context), headers: ["X-Registry-Config: \(header)"])
        builder.state.withLock { $0.failure = nil }
        let refused = try await post(harness, "t=m231-cred", body: B.tar([("hello", "hi")]), headers: ["X-Registry-Config: \(header)"])
        #expect(refused.head.hasPrefix("HTTP/1.1 500"))

        // Control: the builder was given them, keyed as the engine names registries.
        let given = try #require(builder.requests.first?.credentials)
        #expect(Set(given.keys) == ["docker.io", "localhost:5999"])
        #expect(given["docker.io"]?.username == "m231user")
        #expect(given["docker.io"]?.secret == secret)
        #expect(given["localhost:5999"]?.secret == secret + "-tok")
        // Control: the log has the requests in it.
        #expect(log.text.contains("/build"))
        #expect(!log.text.contains(secret))
        #expect(!log.text.contains(header))
        #expect(!"\(builder.requests)".contains(secret))
    }

    @Test("X-Registry-Config decodes from either base64 alphabet; a bad header is no credentials")
    func configHeader() {
        let config = #"{"https://index.docker.io/v1/":{"username":"a","password":"p?>~"},"":{"username":"b","password":"q","serveraddress":"http://reg.local:5000"}}"#
        for header in [RegistryAuthTests.base64url(config), Data(config.utf8).base64EncodedString()] {
            let decoded = DockerRegistryAuth.credentials(configHeader: header)
            #expect(Set(decoded.keys) == ["docker.io", "reg.local:5000"])
            #expect(decoded["docker.io"]?.secret == "p?>~")
            #expect(decoded["reg.local:5000"]?.username == "b")
        }
        for header in [nil, "", "%%%", RegistryAuthTests.base64url("[1]"), RegistryAuthTests.base64url(#"{"x":"not an object"}"#)] {
            #expect(DockerRegistryAuth.credentials(configHeader: header).isEmpty, "\(header ?? "nil")")
        }
    }

    @Test("build/prune answers that nothing was pruned")
    func prune() async throws {
        let request = try DockerRequest(method: .POST, uri: "/v1.48/build/prune?all=1", headers: [:], body: ByteBuffer())
        guard case .data(let status, _, let body, _) = await router().respond(to: request) else {
            Issue.record("expected a whole response")
            return
        }
        #expect(status == .ok)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(String(buffer: body).utf8)) as? [String: Any])
        #expect((report["CachesDeleted"] as? [Any])?.isEmpty == true)
        #expect(report["SpaceReclaimed"] as? Int == 0)
        #expect(report.count == 2)
    }
}
