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
import Testing

@testable import DockerAPIService

/// `docker ps --size`, `docker inspect --size` and `docker export`.
@Suite(.timeLimit(.minutes(1)))
struct ContainerSizeExportTests {
    static let box = String(ToolHarness.boxID.prefix(12))
    static let off = String(ToolHarness.stoppedID.prefix(12))

    /// The engine measures `box` (50 MiB written) and `off` (nothing written); it cannot tell
    /// `term`'s.
    static func start() async throws -> ToolHarness {
        let h = try await ToolHarness.start()
        h.tools.base.writableSizes = [box: 52_428_800, off: 0]
        return h
    }

    static func sizes(_ answer: ToolHarness.Answer) throws -> [String: Any?] {
        let list = try #require(try JSONSerialization.jsonObject(with: Data(answer.body)) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: list.map { (($0["Names"] as? [String])?.first ?? "", $0["SizeRw"]) })
    }

    @Test("ps --size reports what each container wrote, leaves out zero as dockerd does, and what the engine cannot tell")
    func list() async throws {
        let h = try await Self.start()
        defer { Task { try? await h.stop() } }
        let sized = try Self.sizes(try await h.request("GET", "/containers/json?all=1&size=1"))
        #expect(sized["/box"] as? Int == 52_428_800)
        #expect(sized["/off"].map { $0 == nil } == true)
        #expect(sized["/term"].map { $0 == nil } == true)
        // Control: without size=1 nothing is measured, as dockerd does not.
        let plain = try Self.sizes(try await h.request("GET", "/containers/json?all=1"))
        #expect(plain["/box"].map { $0 == nil } == true)
    }

    @Test("inspect --size reports SizeRw, zero included, and leaves it out when the engine cannot tell")
    func inspect() async throws {
        let h = try await Self.start()
        defer { Task { try? await h.stop() } }
        let box = try await h.request("GET", "/containers/box/json?size=1").json()
        #expect(box["SizeRw"] as? Int == 52_428_800)
        // The image's unpacked size here is a disk image's, not dockerd's: never reported.
        #expect(box["SizeRootFs"] == nil)
        #expect(try await h.request("GET", "/containers/off/json?size=1").json()["SizeRw"] as? Int == 0)
        #expect(try await h.request("GET", "/containers/term/json?size=1").json()["SizeRw"] == nil)
        // Control: without size=1 there is no SizeRw.
        #expect(try await h.request("GET", "/containers/box/json").json()["SizeRw"] == nil)
    }

    @Test("container prune reclaims what the removed containers wrote, and nothing for one the engine cannot measure")
    func pruneReclaimed() async throws {
        let engine = FakeEngine(snapshots: [
            Fixtures.dockerContainer(name: "wrote", dockerID: Fixtures.id("a1"), status: .stopped, exitCode: 0),
            Fixtures.dockerContainer(name: "unknown", dockerID: Fixtures.id("a2"), status: .stopped, exitCode: 0),
            Fixtures.dockerContainer(name: "up", dockerID: Fixtures.id("a3")),
        ])
        engine.writableSizes = [String(Fixtures.id("a1").prefix(12)): 8192, String(Fixtures.id("a3").prefix(12)): 1 << 20]
        var router = DockerRouter()
        ContainerRoutes.register(on: &router, engine: engine, identities: DockerIdentityStore(persistence: nil), streams: DockerContainerStreams(engine: engine))
        guard case .data(let status, _, let body, _) = await router.respond(to: try DockerRequest(method: .POST, uri: "/v1.48/containers/prune", headers: [:], body: ByteBuffer()))
        else {
            Issue.record("expected a whole response")
            return
        }
        #expect(status == .ok)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(String(buffer: body).utf8)) as? [String: Any])
        #expect((report["ContainersDeleted"] as? [String])?.count == 2)
        // Control: the running container is kept, so its megabyte is not counted.
        #expect(report["SpaceReclaimed"] as? Int == 8192)
    }

    @Test("export streams the engine's tar of a running or stopped container, and removes it once sent")
    func export() async throws {
        let h = try await Self.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "etc"), withIntermediateDirectories: true)
        try Data("alpine\n".utf8).write(to: h.tools.root.appending(path: "etc/hostname"))

        for name in ["box", "off"] {
            let answer = try await h.request("GET", "/containers/\(name)/export")
            #expect(answer.status == 200)
            #expect(answer.header("Content-Type") == "application/x-tar")
            let entries = try ArchiveRouteTests.tarEntries(answer.body)
            #expect(entries["etc/hostname"] == "alpine\n")
        }
        // The engine wrote each archive into a scratch directory of its own, gone once sent.
        let archives = h.tools.exportCalls
        #expect(archives.count == 2)
        #expect(Set(archives.map { $0.deletingLastPathComponent() }).count == 2)
        #expect(archives.allSatisfy { $0.path.hasPrefix(h.tools.scratch.path) })
        #expect(await StreamHarness.eventually { ((try? FileManager.default.contentsOfDirectory(atPath: h.tools.scratch.path)) ?? ["?"]).isEmpty })
    }

    @Test("a client that leaves mid-export leaves no staged archive behind")
    func exportAbandoned() async throws {
        let h = try await Self.start()
        defer { Task { try? await h.stop() } }
        // Far more than the socket buffers, so the stream is still going when the client goes.
        try Data(count: 32 << 20).write(to: h.tools.root.appending(path: "big"))
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/box/export HTTP/1.1\r\nHost: d\r\n\r\n")
            _ = try await client.iterator.next()
            // Leaving the closure closes the connection with the body unread.
        }
        #expect(h.tools.exportCalls.count == 1)
        #expect(await StreamHarness.eventually { ((try? FileManager.default.contentsOfDirectory(atPath: h.tools.scratch.path)) ?? ["?"]).isEmpty })
    }

    @Test("an export the engine fails is an error status, not a truncated tar, and leaves nothing behind")
    func exportFails() async throws {
        let h = try await Self.start()
        defer { Task { try? await h.stop() } }
        h.tools.exportError = POSIXError(.ENOSPC)
        let answer = try await h.request("GET", "/containers/box/export")
        #expect(answer.status == 500)
        #expect((try answer.json()["message"] as? String)?.hasPrefix("could not export container box: ") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.tools.scratch.path)) ?? ["?"]).isEmpty)

        // A client error from the engine keeps its status.
        h.tools.exportError = DockerAPIError.conflict("container must be running or stopped")
        #expect(try await h.request("GET", "/containers/box/export").status == 409)

        // Control: an unknown container is dockerd's 404, and the engine is not asked.
        let calls = h.tools.exportCalls.count
        let missing = try await h.request("GET", "/containers/nothing/export")
        #expect(missing.status == 404)
        #expect(h.tools.exportCalls.count == calls)
    }
}
