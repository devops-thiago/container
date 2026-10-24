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
import Synchronization
import Testing

@testable import DockerAPIService

/// Uploads into a container that is not running: a start that races them, an agent that
/// restarts while they are held, an upload whose record cannot be read, an entry that cannot
/// be copied in, a start this service did not see, and a removal.
@Suite(.timeLimit(.minutes(1)))
struct PendingCopiesTests {
    static let stopped = String(ToolHarness.stoppedID.prefix(12))
    static let otherID = Fixtures.id("0ff2")
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

    @Test("a racing start gets the upload and preserves its no-overwrite policy", arguments: [false, true])
    func startDuringUpload(strict: Bool) async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let gate = DockerLatch()
        h.tools.with {
            $0.copyBeforeStart = true
            $0.copyBeforeStartGate = gate
        }
        let path = Self.upload.replacingOccurrences(of: "noOverwriteDirNonDir=false", with: "noOverwriteDirNonDir=\(strict)")
        let put = Task { try await h.request("PUT", path, body: Self.tar([("hello.txt", "hello\n")]), contentType: "application/x-tar") }
        // The upload has seen the container stopped and waits before it unpacks.
        #expect(await StreamHarness.eventually { h.tools.with { $0.copyBeforeStartChecks } == 1 })
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        // The start found nothing to copy in.
        #expect(h.tools.copyCalls.isEmpty)
        gate.open()
        #expect(try await put.value.status == 200)
        #expect(Self.contents(h, "hello.txt") == "hello\n")
        #expect(h.tools.copyCalls == ["in hello.txt / 644"])
        #expect(h.tools.copyNoOverwriteCalls == [strict])
        #expect(!h.streams.copies.holds(Self.stopped))
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
        #expect(!h.streams.copies.holds(Self.stopped))
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
        #expect(copies.holds(Self.stopped))
        let second = try await ToolHarness.start(tools: tools, copies: copies)
        defer { Task { try? await second.stop(keepEngine: true) } }
        #expect(try await second.request("POST", "/containers/off/start").status == 204)
        #expect(tools.copyCalls == ["in one.txt /data 644", "in two.txt /data 644"])
        #expect(Self.contents(second, "data/one.txt") == "1")
        #expect(tools.copyInStatusCalls == [.stopped, .stopped])
        #expect(!copies.holds(Self.stopped))
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

    @Test("an unknown record version is retained unchanged across restart and never replayed")
    func unsupportedVersion() async throws {
        let tools = try FakeTools(snapshots: ToolHarness.snapshots())
        defer { tools.cleanup() }
        tools.with { $0.copyBeforeStart = true }
        let first = try await ToolHarness.start(tools: tools)
        #expect(try await first.request("PUT", Self.upload, body: Self.tar([("keep.txt", "keep these bytes")])).status == 200)
        try await first.stop(keepEngine: true)
        let queue = tools.queue.directory.appending(path: "pending/\(Self.stopped)")
        let name = try #require(Self.names(in: queue).first)
        let upload = queue.appending(path: name)
        let recordURL = upload.appending(path: PendingCopyQueue.recordName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        object["version"] = 2
        let record = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try record.write(to: recordURL)
        let payloadURL = PendingCopyQueue.root(of: upload).appending(path: "keep.txt")
        let payload = try Data(contentsOf: payloadURL)
        for _ in 0..<2 {
            let service = try await ToolHarness.start(tools: tools, copies: DockerPendingCopies(queue: tools.queue))
            let response = try await service.request("POST", "/containers/off/start")
            #expect(response.status == 500)
            #expect(((try? response.json())?["message"] as? String)?.contains("unsupported pending-copy record version 2") == true)
            #expect(tools.copyCalls.isEmpty)
            #expect((try? Data(contentsOf: recordURL)) == record)
            #expect((try? Data(contentsOf: payloadURL)) == payload)
            try await service.stop(keepEngine: true)
        }
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
        #expect(h.streams.copies.holds(Self.stopped))
        // Kept on disk as it is now: what failed and what was never tried.
        #expect(try Self.held(tools.queue, Self.stopped) == [["b.txt"], ["c.txt"]])

        tools.with { $0.copyInFailures = [:] }
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        // What went in the first time is not copied again.
        #expect(tools.copyCalls == ["in a.txt /data 644", "in b.txt /data 644", "in b.txt /data 644", "in c.txt /data 644"])
        #expect(["a.txt", "b.txt", "c.txt"].map { Self.contents(h, "data/\($0)") } == ["a", "b", "c"])
        #expect(!h.streams.copies.holds(Self.stopped))
        #expect(ArchiveRouteTests.scratchEntries(h).isEmpty)
    }

    @Test("a container started without this service, as `container start` starts it, has what was held copied in before its process runs")
    func startedElsewhere() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("early.txt", "early")])).status == 200)
        // The engine's own start: bootstrap, then the process, with no request to this service.
        let snapshot = try #require(try await h.tools.get(Self.stopped))
        let process = try await h.tools.bootstrap(snapshot, stdio: DockerProcessStdio(), requester: nil)
        #expect(Self.contents(h, "early.txt") == "early")
        try await process.start()
        // Copied in while the container was booted and its process not yet started.
        #expect(h.tools.copyInStatusCalls == [.stopped])
        #expect(!h.streams.copies.holds(Self.stopped))
        #expect(ArchiveRouteTests.scratchEntries(h).isEmpty)
    }

    /// Whether a request has answered.
    final class Answered: Sendable {
        let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
    }

    @Test("an upload a start takes with the queue is answered once the start has copied it in, or once the start fails and it is held again")
    func uploadTakenByStart() async throws {
        for failing in [false, true] {
            let tools = try FakeTools(snapshots: ToolHarness.snapshots())
            defer { tools.cleanup() }
            tools.with { $0.copyBeforeStart = true }
            let committed = DockerLatch()
            let copies = DockerPendingCopies(queue: tools.queue, startWait: .seconds(10), afterCommit: { await committed.wait() })
            let h = try await ToolHarness.start(tools: tools, copies: copies)
            defer { Task { try? await h.stop(keepEngine: true) } }
            let answered = Answered()
            let put = Task {
                defer { answered.value.withLock { $0 = true } }
                return try await h.request("PUT", Self.upload, body: Self.tar([("late.txt", "late")]))
            }
            // In the queue, not yet looked at it.
            #expect(await StreamHarness.eventually { tools.queue.holds(Self.stopped) })
            let copying = DockerLatch()
            tools.with {
                $0.copyInGate = copying
                if failing { $0.copyInFailures["late.txt"] = DockerAPIError.internalError("disk full") }
            }
            let start = Task { try await h.request("POST", "/containers/off/start") }
            // The start took it and is copying it in.
            #expect(await StreamHarness.eventually { tools.copyCalls == ["in late.txt / 644"] })
            committed.open()
            // The upload finds the queue taken and itself gone with it: it waits for the start.
            try await Task.sleep(for: .milliseconds(200))
            #expect(!answered.isSet)
            copying.open()
            #expect(try await start.value.status == (failing ? 500 : 204))
            #expect(try await put.value.status == 200)
            if failing {
                // Held again for the next start, which copies it in.
                #expect(h.streams.copies.holds(Self.stopped))
                tools.with { $0.copyInFailures = [:] }
                #expect(try await h.request("POST", "/containers/off/start").status == 204)
            }
            #expect(Self.contents(h, "late.txt") == "late")
            #expect(!h.streams.copies.holds(Self.stopped))
        }
    }

    @Test("removing a container drops what was held for it")
    func deleteDropsQueue() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        #expect(try await h.request("PUT", Self.upload, body: Self.tar([("x.txt", "x")])).status == 200)
        #expect(h.streams.copies.holds(Self.stopped))
        #expect(try await h.request("DELETE", "/containers/off").status == 204)
        #expect(!FileManager.default.fileExists(atPath: h.tools.queue.directory.appending(path: "pending/\(Self.stopped)").path))
        #expect(ArchiveRouteTests.scratchEntries(h).isEmpty)
    }
}
