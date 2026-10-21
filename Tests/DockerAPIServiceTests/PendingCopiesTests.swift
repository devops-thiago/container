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
import Testing

@testable import DockerAPIService

/// Uploads into a container that is not running: a start that races them, an agent that
/// restarts while they are held, an entry that cannot be copied in, and a start this service
/// did not see.
@Suite(.timeLimit(.minutes(1)))
struct PendingCopiesTests {
    static let stopped = String(ToolHarness.stoppedID.prefix(12))
    static let upload = "/containers/off/archive?path=%2F&noOverwriteDirNonDir=false&copyUIDGID=false"

    static func tar(_ files: [(String, String)]) -> [UInt8] {
        var tar = TarBuilder()
        for (name, content) in files { tar.file(name, content) }
        return tar.archive
    }

    static func contents(_ h: ToolHarness, _ path: String) -> String? {
        try? String(contentsOf: h.tools.root.appending(path: path), encoding: .utf8)
    }

    /// Where an agent over `tools` keeps what it holds.
    static func stateDirectory(_ tools: FakeTools) -> URL {
        tools.root.deletingLastPathComponent().appending(path: "state/pending-copies", directoryHint: .isDirectory)
    }

    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    static func manifest(_ directory: URL) throws -> DockerPendingCopies.Manifest {
        try JSONDecoder().decode(DockerPendingCopies.Manifest.self, from: Data(contentsOf: directory.appending(path: DockerPendingCopies.manifestName)))
    }

    @Test("a start between an upload's look at the container and its hold gets the files from the upload itself, never a 200 without them")
    func startDuringUpload() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let gate = DockerLatch()
        h.tools.with {
            $0.copyBeforeStart = true
            $0.copyBeforeStartGate = gate
        }
        let put = Task { try await h.request("PUT", Self.upload, body: Self.tar([("hello.txt", "hello\n")]), contentType: "application/x-tar") }
        // The upload has seen the container stopped and waits before it unpacks.
        #expect(await StreamHarness.eventually { h.tools.with { $0.copyBeforeStartChecks } == 1 })
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        // The start found nothing to copy in.
        #expect(h.tools.copyCalls.isEmpty)
        gate.open()
        #expect(try await put.value.status == 200)
        #expect(Self.contents(h, "hello.txt") == "hello\n")
        #expect(h.tools.copyCalls == ["in hello.txt / 644"])
        #expect(await !h.streams.copies.holds(Self.stopped))
        #expect(await StreamHarness.eventually { ArchiveRouteTests.scratchEntries(h).isEmpty })
    }

    @Test("an upload while a start copies in what was held goes in before the start ends, not at the next one")
    func uploadWhileStartCopies() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("first.txt", "1")])).status == 200)
        let gate = DockerLatch()
        h.tools.with { $0.copyInGate = gate }
        let start = Task { try await h.request("POST", "/containers/off/start") }
        // The start is copying in the held upload and has not started the process.
        #expect(await StreamHarness.eventually { h.tools.copyCalls == ["in first.txt / 644"] })
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("second.txt", "2")])).status == 200)
        #expect(Self.contents(h, "second.txt") == "2")
        gate.open()
        #expect(try await start.value.status == 204)
        #expect(Self.contents(h, "first.txt") == "1")
        #expect(await !h.streams.copies.holds(Self.stopped))
        #expect(await StreamHarness.eventually { ArchiveRouteTests.scratchEntries(h).isEmpty })
    }

    @Test("what is held outlives the service: a new one over the same directory holds it, and the start copies it in")
    func survivesRestart() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let directory = Self.stateDirectory(tools)
        let first = try await ToolHarness.start(tools: tools, copies: try DockerPendingCopies(directory: directory))
        #expect(try await first.request("PUT", "/containers/off/archive?path=/data", body: Self.tar([("hello.txt", "kept\n")])).status == 200)
        // Held where the service keeps it, not in the engine's scratch directory.
        #expect(ArchiveRouteTests.scratchEntries(first).isEmpty)
        #expect(Self.names(in: directory).count == 2)
        try await first.stop(keepEngine: true)
        // Stopping keeps it.
        #expect(Self.names(in: directory).count == 2)

        // Left by an upload that never finished: it goes when the next service starts.
        let stray = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let copies = try DockerPendingCopies(directory: directory)
        #expect(await copies.holds(Self.stopped))
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
        let second = try await ToolHarness.start(tools: tools, copies: copies)
        defer { Task { try? await second.stop(keepEngine: true) } }
        #expect(try await second.request("POST", "/containers/off/start").status == 204)
        #expect(Self.contents(second, "data/hello.txt") == "kept\n")
        #expect(tools.copyInStatusCalls == [.stopped])
        #expect(await !copies.holds(Self.stopped))
        #expect(Self.names(in: directory) == [DockerPendingCopies.manifestName])
        #expect(try Self.manifest(directory).uploads.isEmpty)
    }

    @Test("an entry that cannot be copied in fails the start naming it; it and what follows stay held, and the next start copies them in")
    func partialFailure() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let directory = Self.stateDirectory(tools)
        let h = try await ToolHarness.start(tools: tools, copies: try DockerPendingCopies(directory: directory))
        defer { Task { try? await h.stop(keepEngine: true) } }
        #expect(try await h.request("PUT", "/containers/off/archive?path=/data", body: Self.tar([("a.txt", "a"), ("b.txt", "b")])).status == 200)
        #expect(try await h.request("PUT", "/containers/off/archive?path=/data", body: Self.tar([("c.txt", "c")])).status == 200)
        tools.with { $0.copyInFailures["b.txt"] = DockerAPIError.internalError("disk full") }

        let failed = try await h.request("POST", "/containers/off/start")
        #expect(failed.status == 500)
        #expect((try failed.json()["message"] as? String)?.contains("could not copy b.txt into /data before the start: disk full") == true)
        #expect(tools.copyCalls == ["in a.txt /data 644", "in b.txt /data 644"])
        #expect(await h.streams.copies.holds(Self.stopped))
        // Kept on disk as it is now: what failed and what was never tried.
        #expect(try Self.manifest(directory).uploads.map { $0.entries.map(\.name) } == [["b.txt"], ["c.txt"]])

        tools.with { $0.copyInFailures = [:] }
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        // What went in the first time is not copied again.
        #expect(tools.copyCalls == ["in a.txt /data 644", "in b.txt /data 644", "in b.txt /data 644", "in c.txt /data 644"])
        #expect(["a.txt", "b.txt", "c.txt"].map { Self.contents(h, "data/\($0)") } == ["a", "b", "c"])
        #expect(await !h.streams.copies.holds(Self.stopped))
        #expect(Self.names(in: directory) == [DockerPendingCopies.manifestName])
    }

    @Test("a container started where the service did not see it gets what was held at the next request that finds it running")
    func startedElsewhere() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("early.txt", "early")])).status == 200)
        // `container start`, or the app.
        h.tools.base.update(Self.stopped) { $0.status = .running }
        #expect(try await h.request("POST", "/containers/off/start").status == 304)
        #expect(Self.contents(h, "early.txt") == "early")
        #expect(await !h.streams.copies.holds(Self.stopped))
        #expect(await StreamHarness.eventually { ArchiveRouteTests.scratchEntries(h).isEmpty })

        // Held, started elsewhere, then another upload: the held one goes in first.
        h.tools.base.update(Self.stopped) { $0.status = .stopped }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("order.txt", "held")])).status == 200)
        h.tools.base.update(Self.stopped) { $0.status = .running }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("order.txt", "later")])).status == 200)
        #expect(Self.contents(h, "order.txt") == "later")
        #expect(Array(h.tools.copyCalls.suffix(2)) == ["in order.txt / 644", "in order.txt / 644"])
        #expect(await !h.streams.copies.holds(Self.stopped))
    }

    @Test("a restarted service copies in what is held for a container started meanwhile, and drops what is held for one that is gone")
    func reconcileAfterRestart() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let directory = Self.stateDirectory(tools)
        let first = try await ToolHarness.start(tools: tools, copies: try DockerPendingCopies(directory: directory))
        #expect(try await first.request("PUT", Self.upload, body: Self.tar([("meanwhile.txt", "m")])).status == 200)
        try await first.stop(keepEngine: true)

        tools.base.update(Self.stopped) { $0.status = .running }
        let copies = try DockerPendingCopies(directory: directory)
        let streams = DockerContainerStreams(engine: tools, copies: copies)
        await streams.reconcileHeldCopies(engine: tools)
        #expect(try String(contentsOf: tools.root.appending(path: "meanwhile.txt"), encoding: .utf8) == "m")
        #expect(await !copies.holds(Self.stopped))

        // Held for a container that is then removed while no service runs.
        tools.base.update(Self.stopped) { $0.status = .stopped }
        let third = try await ToolHarness.start(tools: tools, copies: copies)
        #expect(try await third.request("PUT", Self.upload, body: Self.tar([("gone.txt", "g")])).status == 200)
        try await third.stop(keepEngine: true)
        let snapshot = try #require(try await tools.get(Self.stopped))
        try await tools.delete(snapshot, force: true)
        let after = try DockerPendingCopies(directory: directory)
        #expect(await after.holds(Self.stopped))
        await DockerContainerStreams(engine: tools, copies: after).reconcileHeldCopies(engine: tools)
        #expect(await !after.holds(Self.stopped))
        #expect(Self.names(in: directory) == [DockerPendingCopies.manifestName])
    }
}
