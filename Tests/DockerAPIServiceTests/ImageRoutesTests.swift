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

import ContainerResource
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import DockerAPIService

/// The image routes over the router, and save, load and push over a real socket.
@Suite(.timeLimit(.minutes(1)))
struct ImageRoutesTests {
    typealias F = StoreFixtures

    let images: FakeImageStore
    let engine: FakeEngine
    let identities = DockerIdentityStore(persistence: nil)
    let scratch: URL
    let router: DockerRouter

    init(_ records: [EngineImageRecord] = ImageCatalogTests.catalog.images.flatMap(\.records), containers: [ContainerSnapshot] = []) throws {
        images = FakeImageStore(records + [ImageCatalogTests.vminit])
        engine = FakeEngine(snapshots: containers)
        scratch = FileManager.default.temporaryDirectory.appending(path: "dapi-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var router = DockerRouter()
        ImageRoutes.register(on: &router, engine: images, containers: engine, identities: identities, scratch: scratch, progressInterval: .milliseconds(1))
        self.router = router
    }

    init() throws {
        try self.init(ImageCatalogTests.catalog.images.flatMap(\.records))
    }

    func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws -> ContainerRoutesTests.Answer {
        let request = try DockerRequest(method: method, uri: "/v1.48" + uri, headers: [:], body: ByteBuffer(string: body))
        guard case .data(let status, _, let buffer, _) = await router.respond(to: request) else {
            Issue.record("expected a whole response")
            return .init(status: .internalServerError, body: "")
        }
        return .init(status: status, body: String(buffer: buffer))
    }

    func scratchFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))
    }

    /// Files are deleted off the event loop once an answer is sent: waits up to 5 s for it.
    func waitForEmptyScratch() async throws {
        for _ in 0..<500 where !(try scratchFiles().isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("list, inspect and history answer Docker's shapes; a missing image is dockerd's 404")
    func readRoutes() async throws {
        let routes = try ImageRoutesTests()
        let list = try #require(try await routes.call(.GET, "/images/json").json() as? [[String: Any]])
        #expect(list.map { $0["Id"] as? String } == [F.digest("a"), F.digest("b"), F.digest("c"), F.digest("e")])
        #expect(list.allSatisfy { $0["Manifests"] == nil })
        let filtered = try #require(
            try await routes.call(.GET, "/images/json?manifests=1&filters=%7B%22reference%22%3A%5B%22redis%22%5D%7D").json() as? [[String: Any]])
        #expect(filtered.count == 1)
        #expect((filtered.first?["Manifests"] as? [Any])?.count == 3)
        #expect(try await routes.call(.GET, "/images/json?filters=%7B%22colour%22%3A%5B%22x%22%5D%7D").status == .badRequest)

        let inspect = try #require(try await routes.call(.GET, "/images/ghcr.io/org/app:1/json").json() as? [String: Any])
        #expect(inspect["Id"] as? String == F.digest("c"))
        #expect(inspect["RepoTags"] as? [String] == ["ghcr.io/org/app:1"])
        let history = try #require(try await routes.call(.GET, "/images/redis:8/history").json() as? [[String: Any]])
        #expect(history.count == 3)

        let missing = try await routes.call(.GET, "/images/nginx/json")
        #expect(missing.status == .notFound)
        #expect(missing.message == "No such image: nginx:latest")
        // Control: the engine's own image is as missing as one that does not exist.
        #expect(try await routes.call(.GET, "/images/ghcr.io/apple/containerization/vminit:0.9/json").status == .notFound)
    }

    @Test("tag makes the reference in normal form, and refuses what dockerd refuses")
    func tag() async throws {
        let routes = try ImageRoutesTests()
        #expect(try await routes.call(.POST, "/images/redis:8/tag?repo=m229-cache&tag=v1").status == .created)
        #expect(try await routes.call(.POST, "/images/bbbb/tag?repo=localhost:5000/team/cache").status == .created)
        #expect(
            routes.images.calls == [
                "tag docker.io/library/redis:8 docker.io/library/m229-cache:v1",
                // By ID, the image's first tagged reference is the source.
                "tag docker.io/library/m229-cache:v1 localhost:5000/team/cache:latest",
            ])
        #expect(try await routes.call(.POST, "/images/redis:8/tag?repo=").message == "repository name must have at least one component")
        #expect(try await routes.call(.POST, "/images/redis:8/tag?repo=Bad").status == .badRequest)
        #expect(try await routes.call(.POST, "/images/redis:8/tag?repo=x&tag=bad:tag").message == "invalid tag format")
        #expect(try await routes.call(.POST, "/images/redis:8/tag?repo=sha256").message == "refusing to create an ambiguous tag using digest algorithm as name")
        #expect(try await routes.call(.POST, "/images/nginx/tag?repo=x").status == .notFound)
        #expect(routes.images.calls.count == 2)
    }

    @Test("delete untags, deletes, collects, and answers 409 for an image a container uses")
    func delete() async throws {
        let redis = ImageCatalogTests.redis
        let routes = try ImageRoutesTests(
            [ImageCatalogTests.alpine, ImageCatalogTests.mine, redis], containers: [F.container("cafe", image: redis, run: .exited)])
        let untag = try await routes.call(.DELETE, "/images/m229-x:1")
        #expect(untag.status == .ok)
        #expect(untag.body == #"[{"Untagged":"m229-x:1"}]"#)
        #expect(routes.images.calls == ["delete docker.io/library/m229-x:1"])

        let conflict = try await routes.call(.DELETE, "/images/redis:8")
        #expect(conflict.status == .conflict)
        #expect(conflict.message?.hasSuffix("is using its referenced image bbbbbbbbbbbb") == true)
        #expect(routes.images.references.contains("docker.io/library/redis:8"))

        let forced = try await routes.call(.DELETE, "/images/redis:8?force=1")
        #expect(forced.body == #"[{"Untagged":"redis:8"},{"Deleted":"\#(F.digest("b"))"}]"#)
        #expect(routes.images.calls.suffix(2) == ["delete docker.io/library/redis:8", "gc"])

        // noprune leaves the content for the engine to collect later.
        let last = try await routes.call(.DELETE, "/images/alpine?noprune=1")
        #expect(last.status == .ok)
        #expect(routes.images.calls.last == "delete docker.io/library/alpine:latest")
        #expect(routes.images.references == ["ghcr.io/apple/containerization/vminit:0.9"])
    }

    @Test("prune removes what it selects, collects only when something went, and reports it")
    func prune() async throws {
        let routes = try ImageRoutesTests()
        let none = try #require(try await routes.call(.POST, "/images/prune?filters=%7B%22label%22%3A%5B%22m229%3D2%22%5D%7D").json() as? [String: Any])
        #expect(none["SpaceReclaimed"] as? Int == 0)
        #expect(none["ImagesDeleted"] == nil)
        #expect(!routes.images.calls.contains("gc"))

        let report = try #require(
            try await routes.call(.POST, "/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%2C%22label%22%3A%5B%22m229%3D1%22%5D%7D").json()
                as? [String: Any])
        let deleted = try #require(report["ImagesDeleted"] as? [[String: String]])
        #expect(deleted.compactMap { $0["Deleted"] } == [F.digest("c"), F.digest("e")])
        #expect(report["SpaceReclaimed"] as? Int == 1234)
        #expect(routes.images.references.contains("docker.io/library/redis:8"))
        #expect(routes.images.references.contains("ghcr.io/apple/containerization/vminit:0.9"))
    }

    /// Sends one request on its own connection and returns the head and the de-chunked body.
    static func exchange(_ harness: DockerAPIServerTests.Harness, _ request: String, body: [UInt8] = []) async throws -> (head: String, body: [UInt8]) {
        var answer = ""
        try await harness.withClient { client in
            try await client.send(request)
            if !body.isEmpty {
                try await client.outbound.write(ByteBuffer(bytes: body))
            }
            answer = try await client.readToEnd()
        }
        guard let split = answer.range(of: "\r\n\r\n") else { return (answer, []) }
        let head = String(answer[..<split.lowerBound])
        var rest = Array(answer[split.upperBound...].utf8)
        guard head.lowercased().contains("transfer-encoding: chunked") else { return (head, rest) }
        var decoded: [UInt8] = []
        while let line = rest.firstIndex(of: UInt8(ascii: "\r")), let size = Int(String(decoding: rest[..<line], as: UTF8.self), radix: 16), size > 0 {
            decoded += rest[(line + 2)..<(line + 2 + size)]
            rest = Array(rest[(line + 2 + size + 2)...])
        }
        return (head, decoded)
    }

    @Test("save streams the engine's archive from scratch and deletes it; a missing image is a 404 before the head")
    func save() async throws {
        let routes = try ImageRoutesTests()
        let images = routes.images
        let engine = routes.engine
        let identities = routes.identities
        let scratch = routes.scratch
        let harness = try await DockerAPIServerTests.Harness.start {
            ImageRoutes.register(on: &$0, engine: images, containers: engine, identities: identities, scratch: scratch)
        }
        defer { Task { try? await harness.stop() } }
        let one = try await Self.exchange(harness, "GET /v1.48/images/redis:8/get HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        #expect(one.head.hasPrefix("HTTP/1.1 200"))
        #expect(one.head.contains("Content-Type: application/x-tar"))
        #expect(String(decoding: one.body, as: UTF8.self) == "archive of docker.io/library/redis:8 for host")
        let two = try await Self.exchange(
            harness, "GET /v1.48/images/get?names=redis:8&names=aaaa&platform=linux/amd64 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        #expect(String(decoding: two.body, as: UTF8.self) == "archive of docker.io/library/redis:8,docker.io/library/alpine:3.22 for linux/amd64")
        #expect(try routes.scratchFiles().isEmpty)
        let missing = try await Self.exchange(harness, "GET /v1.48/images/get?names=redis:8&names=nope HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        #expect(missing.head.hasPrefix("HTTP/1.1 404"))
        #expect(images.calls.filter { $0.hasPrefix("save") }.count == 2)
    }

    @Test("load spools a body past the memory limit to scratch, answers Loaded image lines, and deletes the file")
    func load() async throws {
        let routes = try ImageRoutesTests()
        let images = routes.images
        let engine = routes.engine
        let identities = routes.identities
        let scratch = routes.scratch
        images.state.withLock {
            $0.loadResult = DockerLoadedImages(references: ["docker.io/library/redis:8", "docker.io/library/old@" + F.digest("e")], rejectedMembers: ["../x"])
        }
        let harness = try await DockerAPIServerTests.Harness.start(limits: .init(maxBodyBytes: 1024, spool: .imageLoad(directory: scratch, maxBytes: 1 << 20))) {
            ImageRoutes.register(on: &$0, engine: images, containers: engine, identities: identities, scratch: scratch)
        }
        defer { Task { try? await harness.stop() } }
        let archive = (0..<(300 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let answer = try await Self.exchange(
            harness, "POST /v1.48/images/load?quiet=1 HTTP/1.1\r\nHost: d\r\nContent-Length: \(archive.count)\r\nConnection: close\r\n\r\n", body: archive)
        #expect(answer.head.hasPrefix("HTTP/1.1 200"))
        let lines = String(decoding: answer.body, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                #"{"stream":"Loaded image: redis:8\n"}"#, #"{"stream":"Loaded image ID: \#(F.digest("e"))\n"}"#,
                #"{"stream":"Skipped archive entries with unsafe paths: ../x\n"}"#,
            ])
        #expect(images.state.withLock { $0.loaded } == [Data(archive)])
        // The spooled file goes once the answer is sent.
        try await routes.waitForEmptyScratch()
        #expect(try routes.scratchFiles().isEmpty)

        // Control: the same body to another route is still held to the memory limit.
        let refused = try await Self.exchange(
            harness, "POST /v1.48/images/redis:8/tag?repo=x HTTP/1.1\r\nHost: d\r\nContent-Length: \(archive.count)\r\nConnection: close\r\n\r\n", body: archive)
        #expect(refused.head.hasPrefix("HTTP/1.1 413"))
        // And a load past the spool's own bound is refused and leaves nothing behind.
        let huge = [UInt8](repeating: 7, count: (1 << 20) + 1)
        let tooLarge = try await Self.exchange(
            harness, "POST /images/load HTTP/1.1\r\nHost: d\r\nContent-Length: \(huge.count)\r\nConnection: close\r\n\r\n", body: huge)
        #expect(tooLarge.head.hasPrefix("HTTP/1.1 413"))
        try await routes.waitForEmptyScratch()
        #expect(try routes.scratchFiles().isEmpty)
        #expect(images.state.withLock { $0.loaded.count } == 1)
    }

    @Test("a client that goes mid-upload leaves no spooled file behind")
    func loadAbandoned() async throws {
        let routes = try ImageRoutesTests()
        let images = routes.images
        let engine = routes.engine
        let identities = routes.identities
        let scratch = routes.scratch
        let harness = try await DockerAPIServerTests.Harness.start(limits: .init(maxBodyBytes: 16, spool: .imageLoad(directory: scratch))) {
            ImageRoutes.register(on: &$0, engine: images, containers: engine, identities: identities, scratch: scratch)
        }
        defer { Task { try? await harness.stop() } }
        try await harness.withClient { client in
            try await client.send("POST /v1.48/images/load HTTP/1.1\r\nHost: d\r\nContent-Length: 100000\r\n\r\n")
            try await client.outbound.write(ByteBuffer(repeating: 1, count: 5000))
            // The body is being spooled: its file exists.
            for _ in 0..<500 where try routes.scratchFiles().isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try routes.scratchFiles().count == 1)
        }
        try await routes.waitForEmptyScratch()
        #expect(try routes.scratchFiles().isEmpty)
        #expect(images.calls.isEmpty)
    }

    @Test("a load that fails is the stream's last line, as dockerd answers it")
    func loadFailure() async throws {
        let routes = try ImageRoutesTests()
        let failing = FailingLoad()
        var router = DockerRouter()
        ImageRoutes.register(on: &router, engine: failing, containers: routes.engine, identities: routes.identities, scratch: routes.scratch)
        let request = try DockerRequest(method: .POST, uri: "/images/load", headers: [:], body: ByteBuffer(string: "not a tar"))
        guard case .stream(let status, _, _) = await router.respond(to: request) else {
            Issue.record("expected a stream")
            return
        }
        #expect(status == .ok)
        // Control: an empty body is refused before the head.
        let empty = try DockerRequest(method: .POST, uri: "/images/load", headers: [:], body: ByteBuffer())
        guard case .data(let refused, _, _, _) = await router.respond(to: empty) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refused == .badRequest)
    }

    struct FailingLoad: EngineImages {
        func pull(reference: String, platform: String?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws -> DockerPulledImage {
            throw DockerAPIError.internalError("no")
        }
        func list() async throws -> [EngineImageRecord] { [] }
        func tag(_ source: String, as target: String) async throws {}
        func delete(_ reference: String) async throws {}
        func collectGarbage() async throws -> UInt64 { 0 }
        func push(reference: String, platform: String?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws -> DockerDescriptor? { nil }
        func save(references: [String], platform: String?, to file: URL) async throws {}
        func load(from file: URL) async throws -> DockerLoadedImages { throw DockerAPIError.badRequest("unrecognised archive") }
    }

    @Test("push streams progress, the digest line and aux; without a tag every tag goes; refusals before the head")
    func push() async throws {
        let routes = try ImageRoutesTests([ImageCatalogTests.ghcr, F.record("ghcr.io/org/app:2", id: "c", target: "d")])
        let images = routes.images
        let engine = routes.engine
        let identities = routes.identities
        let scratch = routes.scratch
        let harness = try await DockerAPIServerTests.Harness.start {
            ImageRoutes.register(on: &$0, engine: images, containers: engine, identities: identities, scratch: scratch, progressInterval: .milliseconds(1))
        }
        defer { Task { try? await harness.stop() } }
        func lines(_ body: [UInt8]) throws -> [[String: Any]] {
            try body.split(separator: UInt8(ascii: "\n")).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        }
        let one = try await Self.exchange(
            harness, "POST /v1.48/images/ghcr.io/org/app/push?tag=1 HTTP/1.1\r\nHost: d\r\nX-Registry-Auth: e30=\r\nConnection: close\r\n\r\n")
        #expect(one.head.hasPrefix("HTTP/1.1 200"))
        let pushed = try lines(one.body)
        #expect(pushed.first?["status"] as? String == "The push refers to repository [ghcr.io/org/app]")
        #expect(pushed.contains { $0["status"] as? String == "Pushing" })
        #expect(pushed.contains { $0["status"] as? String == "1: digest: \(F.digest("d")) size: 500" })
        #expect((pushed.last?["aux"] as? [String: Any])?["Tag"] as? String == "1")
        #expect(images.calls == ["push ghcr.io/org/app:1"])

        _ = try await Self.exchange(harness, "POST /v1.48/images/ghcr.io/org/app/push HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        #expect(images.calls.suffix(2) == ["push ghcr.io/org/app:1", "push ghcr.io/org/app:2"])

        // One platform: the registry's index is not this one, so no digest is claimed.
        let narrowed = try lines(
            try await Self.exchange(harness, "POST /v1.48/images/ghcr.io/org/app/push?tag=1&platform=linux/arm64 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n").body)
        #expect(narrowed.last?["status"] as? String == "Pushed")
        #expect(!narrowed.contains { $0["aux"] != nil || ($0["status"] as? String)?.contains("digest:") == true })

        images.state.withLock { $0.pushFailure = .internalError("denied: requested access to the resource is denied") }
        let failed = try lines(try await Self.exchange(harness, "POST /v1.48/images/ghcr.io/org/app/push?tag=1 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n").body)
        #expect(failed.last?["error"] as? String == "denied: requested access to the resource is denied")
        #expect(!failed.contains { $0["aux"] != nil })

        let missing = try await Self.exchange(harness, "POST /v1.48/images/ghcr.io/org/app/push?tag=9 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
        #expect(missing.head.hasPrefix("HTTP/1.1 404"))
        #expect(String(decoding: missing.body, as: UTF8.self).contains("An image does not exist locally with the tag: ghcr.io/org/app:9"))
    }
}
