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
import Testing

@testable import DockerAPIService

/// Uploads into a container that is not running: a start that races them, an agent that
/// restarts while they are held, an upload whose record cannot be read, an entry that cannot
/// be copied in, and a start this service did not see.
@Suite(.timeLimit(.minutes(1)))
struct PendingCopiesTests {
    static let stopped = String(ToolHarness.stoppedID.prefix(12))
    static let otherID = Fixtures.id("0ff2")
    static let other = String(otherID.prefix(12))
    static let upload = "/containers/off/archive?path=%2F&noOverwriteDirNonDir=false&copyUIDGID=false"

    static func tar(_ files: [(String, String)]) -> [UInt8] {
        var tar = TarBuilder()
        for (name, content) in files { tar.file(name, content) }
        return tar.archive
    }

    static func contents(_ h: ToolHarness, _ path: String) -> String? {
        try? String(contentsOf: h.tools.root.appending(path: path), encoding: .utf8)
    }

    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    /// The uploads held for `container`, in order, as their records name their entries.
    static func held(_ queue: PendingCopyQueue, _ container: String) throws -> [[String]] {
        let directory = queue.directory.appending(path: "pending/\(container)")
        return try names(in: directory).map { name in
            let record = try JSONDecoder().decode(
                PendingCopyQueue.Record.self, from: Data(contentsOf: directory.appending(path: "\(name)/\(PendingCopyQueue.recordName)")))
            return record.entries.map(\.name)
        }
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

    @Test("what is held outlives the service: a new one over the same directory holds it, and the start copies it in in order")
    func survivesRestart() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let first = try await ToolHarness.start(tools: tools)
        // As Testcontainers sends them: one after the other, before the start.
        #expect(try await first.request("PUT", "/containers/off/archive?path=/data", body: Self.tar([("one.txt", "1")])).status == 200)
        #expect(try await first.request("PUT", "/containers/off/archive?path=/data", body: Self.tar([("two.txt", "2")])).status == 200)
        #expect(try Self.held(tools.queue, Self.stopped) == [["one.txt"], ["two.txt"]])
        try await first.stop(keepEngine: true)

        // Left by a service that stopped while it wrote an upload: never committed, so it goes
        // when the next service starts. What was committed stays.
        let staging = tools.queue.directory.appending(path: "staging")
        let stray = staging.appending(path: "\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let copies = DockerPendingCopies(queue: tools.queue)
        #expect(Self.names(in: staging).isEmpty)
        #expect(await copies.holds(Self.stopped))
        let second = try await ToolHarness.start(tools: tools, copies: copies)
        defer { Task { try? await second.stop(keepEngine: true) } }
        #expect(try await second.request("POST", "/containers/off/start").status == 204)
        #expect(tools.copyCalls == ["in one.txt /data 644", "in two.txt /data 644"])
        #expect(Self.contents(second, "data/one.txt") == "1")
        #expect(tools.copyInStatusCalls == [.stopped, .stopped])
        #expect(await !copies.holds(Self.stopped))
        #expect(ArchiveRouteTests.scratchEntries(second).isEmpty)
    }

    @Test("an upload whose record cannot be read is kept, and its container's start fails naming it; other containers start as before")
    func unreadableRecord() async throws {
        let tools = try FakeTools(
            snapshots: ToolHarness.snapshots() + [Fixtures.dockerContainer(name: "off2", dockerID: Self.otherID, status: .stopped, exitCode: 0)])
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let h = try await ToolHarness.start(tools: tools)
        defer { Task { try? await h.stop(keepEngine: true) } }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("bad.txt", "b")])).status == 200)
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("after.txt", "a")])).status == 200)
        #expect(try await h.request("PUT", "/containers/off2/archive?path=/", body: Self.tar([("fine.txt", "f")])).status == 200)
        let queue = tools.queue.directory.appending(path: "pending/\(Self.stopped)")
        let damaged = try #require(Self.names(in: queue).first)
        try Data("{ not a record".utf8).write(to: queue.appending(path: "\(damaged)/\(PendingCopyQueue.recordName)"))

        let failed = try await h.request("POST", "/containers/off/start")
        #expect(failed.status == 500)
        let message = try failed.json()["message"] as? String
        #expect(message?.contains("could not read the copy held in") == true)
        #expect(message?.contains(damaged) == true)
        // Kept, with what follows it; nothing was copied.
        #expect(Self.names(in: queue).count == 2)
        #expect(Self.names(in: queue).first == damaged)
        #expect(tools.copyCalls.isEmpty)
        // Another container's queue is its own.
        #expect(try await h.request("POST", "/containers/off2/start").status == 204)
        #expect(Self.contents(h, "fine.txt") == "f")
        // Again: it is still there, and still named.
        let again = try await h.request("POST", "/containers/off/start")
        #expect(again.status == 500)
        #expect((try again.json()["message"] as? String)?.contains(damaged) == true)
    }

    @Test("an entry that cannot be copied in fails the start naming it; it and what follows stay held, and the next start copies them in")
    func partialFailure() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let h = try await ToolHarness.start(tools: tools)
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
        #expect(try Self.held(tools.queue, Self.stopped) == [["b.txt"], ["c.txt"]])

        tools.with { $0.copyInFailures = [:] }
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        // What went in the first time is not copied again.
        #expect(tools.copyCalls == ["in a.txt /data 644", "in b.txt /data 644", "in b.txt /data 644", "in c.txt /data 644"])
        #expect(["a.txt", "b.txt", "c.txt"].map { Self.contents(h, "data/\($0)") } == ["a", "b", "c"])
        #expect(await !h.streams.copies.holds(Self.stopped))
        #expect(ArchiveRouteTests.scratchEntries(h).isEmpty)
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
    }

    @Test("a restarted service copies in what is held for a container started meanwhile, and drops what is held for one that is gone")
    func reconcileAfterRestart() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let first = try await ToolHarness.start(tools: tools)
        #expect(try await first.request("PUT", Self.upload, body: Self.tar([("meanwhile.txt", "m")])).status == 200)
        try await first.stop(keepEngine: true)

        tools.base.update(Self.stopped) { $0.status = .running }
        let copies = DockerPendingCopies(queue: tools.queue)
        await DockerContainerStreams(engine: tools, copies: copies).reconcileHeldCopies(engine: tools)
        #expect(try String(contentsOf: tools.root.appending(path: "meanwhile.txt"), encoding: .utf8) == "m")
        #expect(await !copies.holds(Self.stopped))

        tools.base.update(Self.stopped) { $0.status = .stopped }
        let third = try await ToolHarness.start(tools: tools, copies: copies)
        #expect(try await third.request("PUT", Self.upload, body: Self.tar([("gone.txt", "g")])).status == 200)
        try await third.stop(keepEngine: true)
        let snapshot = try #require(try await tools.get(Self.stopped))
        try await tools.delete(snapshot, force: true)
        #expect(await copies.holds(Self.stopped))
        await DockerContainerStreams(engine: tools, copies: copies).reconcileHeldCopies(engine: tools)
        #expect(await !copies.holds(Self.stopped))
    }
}
