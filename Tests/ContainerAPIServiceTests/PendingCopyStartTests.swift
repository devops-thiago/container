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

@testable import ContainerAPIService

/// Files uploaded into a container that is not running are copied in by the engine's own start,
/// whoever asks for it, between the container's boot and its process: `container start` and the
/// app included, not only the Docker API agent.
@Suite(.timeLimit(.minutes(1)))
struct PendingCopyStartTests {
    /// Holds `files` for `container`'s next start, as the Docker API agent holds an upload.
    @discardableResult
    static func hold(_ queue: PendingCopyQueue, _ container: String, _ files: [(String, String)], into destination: String = "/data") throws -> String {
        let upload = try queue.stage()
        let root = PendingCopyQueue.root(of: upload)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, content) in files { try Data(content.utf8).write(to: root.appending(path: name)) }
        let record = PendingCopyQueue.Record(
            destination: destination, entries: files.map { PendingCopyQueue.Entry(name: $0.0, isDirectory: false, mode: 0o644) }, requester: nil)
        return try queue.commit(upload, record: record, container: container)
    }

    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test("a start copies in what is held, in the order it was uploaded, before the container's process starts")
    func appliedBeforeProcess() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let queue = PendingCopyQueue(appRoot: f.root)
        let configuration = f.configuration()
        try await f.create(service, configuration)
        // As Testcontainers sends them: one upload after the other, before the start.
        try Self.hold(queue, configuration.id, [("one.txt", "1")])
        try Self.hold(queue, configuration.id, [("two.txt", "2"), ("three.txt", "3")])

        try await f.start(service, configuration.id)
        let runtime = try #require(f.lastRuntime)
        #expect(runtime.calls == ["copyIn one.txt=1 /data", "copyIn two.txt=2 /data", "copyIn three.txt=3 /data", "start"])
        #expect(!queue.holds(configuration.id))
        // Taken for the run: an upload now is copied into the running container.
        #expect(queue.isTaken(configuration.id))
        runtime.exit(0)
        #expect(await Self.eventually { !queue.isTaken(configuration.id) })
        // What was copied in is gone; nothing is left but the empty queue.
        #expect(Self.names(in: queue.directory.appending(path: "pending/\(configuration.id)")).isEmpty)
    }

    @Test("an upload whose record cannot be read fails its container's start naming it and stays; another container starts as before")
    func unreadableRecord() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let queue = PendingCopyQueue(appRoot: f.root)
        let broken = f.configuration()
        let fine = f.configuration()
        try await f.create(service, broken)
        try await f.create(service, fine)
        let damaged = try Self.hold(queue, broken.id, [("bad.txt", "b")])
        try Self.hold(queue, broken.id, [("after.txt", "a")])
        try Self.hold(queue, fine.id, [("fine.txt", "f")])
        let pending = queue.directory.appending(path: "pending/\(broken.id)")
        try Data("{ torn".utf8).write(to: pending.appending(path: "\(damaged)/\(PendingCopyQueue.recordName)"))

        let error = await #expect(throws: (any Error).self) { try await f.start(service, broken.id) }
        #expect("\(error.map { "\($0)" } ?? "")".contains(damaged))
        #expect(f.lastRuntime?.calls == [])
        // Kept, in its place, with what follows it, and the queue is no longer taken.
        #expect(Self.names(in: pending).count == 2)
        #expect(Self.names(in: pending).first == damaged)
        #expect(!queue.isTaken(broken.id))

        try await f.start(service, fine.id)
        #expect(f.lastRuntime?.calls == ["copyIn fine.txt=f /data", "start"])
    }

    @Test("an entry that cannot be copied in fails the start naming it; it and what follows stay held, and the next start copies them in")
    func partialFailure() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        f.behave(FakeRuntime.Behavior(copyInFailures: ["b.txt"]), FakeRuntime.Behavior())
        let service = try f.service()
        let queue = PendingCopyQueue(appRoot: f.root)
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try Self.hold(queue, configuration.id, [("a.txt", "a"), ("b.txt", "b")])
        try Self.hold(queue, configuration.id, [("c.txt", "c")])

        let error = await #expect(throws: (any Error).self) { try await f.start(service, configuration.id) }
        #expect("\(error.map { "\($0)" } ?? "")".contains("could not copy b.txt into /data before the start"))
        #expect(f.lastRuntime?.calls == ["copyIn a.txt=a /data", "copyIn b.txt=b /data"])
        #expect(queue.holds(configuration.id))
        #expect(!queue.isTaken(configuration.id))

        try await f.start(service, configuration.id)
        // What went in the first time is not copied again.
        #expect(f.lastRuntime?.calls == ["copyIn b.txt=b /data", "copyIn c.txt=c /data", "start"])
        #expect(!queue.holds(configuration.id))
    }

    @Test("deleting a container drops what was held for it")
    func deleteDropsQueue() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let queue = PendingCopyQueue(appRoot: f.root)
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try Self.hold(queue, configuration.id, [("x.txt", "x")])
        try await service.delete(id: configuration.id, force: false)
        #expect(!FileManager.default.fileExists(atPath: queue.directory.appending(path: "pending/\(configuration.id)").path(percentEncoded: false)))
    }

    @Test("an engine that starts puts back what a start took and never let go")
    func releasedAtBoot() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let queue = PendingCopyQueue(appRoot: f.root)
        try Self.hold(queue, "left", [("x.txt", "x")])
        try queue.claim("left")
        #expect(queue.isTaken("left"))
        _ = try f.service()
        #expect(!queue.isTaken("left"))
        #expect(queue.holds("left"))
    }

    /// The entries a queue copied in, by name, in order.
    final class CopyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var calls: [String] { lock.withLock { names } }
        func append(_ name: String) { lock.withLock { names.append(name) } }
    }

    struct Refused: Error {}

    static func setMode(_ mode: mode_t, _ url: URL) {
        _ = chmod(url.path(percentEncoded: false), mode)
    }

    static func record(_ upload: URL) throws -> PendingCopyQueue.Record {
        try JSONDecoder().decode(PendingCopyQueue.Record.self, from: Data(contentsOf: upload.appending(path: PendingCopyQueue.recordName)))
    }

    @Test("an entry whose record cannot be rewritten keeps its source; the next start copies it in again and finishes")
    func recordNotRewritten() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let queue = PendingCopyQueue(appRoot: f.root)
        let name = try Self.hold(queue, "c", [("one.txt", "1"), ("two.txt", "2"), ("three.txt", "3")])
        try queue.claim("c")
        let taken = queue.directory.appending(path: "applying/c/\(name)")
        // The record is rewritten through a file beside it, which cannot be made now; what is
        // under root/ can still be removed.
        Self.setMode(0o500, taken)
        defer { Self.setMode(0o700, taken) }
        let log = CopyLog()
        let error = await #expect(throws: (any Error).self) {
            try await queue.apply("c") { source, _, _, _ in
                log.append(source.lastPathComponent)
                if source.lastPathComponent == "two.txt" {
                    Self.setMode(0o700, taken)
                    throw Refused()
                }
            }
        }
        #expect("\(error.map { "\($0)" } ?? "")".contains("could not copy two.txt"))
        #expect(log.calls == ["one.txt", "two.txt"])
        let held = queue.directory.appending(path: "pending/c/\(name)")
        #expect(FileManager.default.fileExists(atPath: PendingCopyQueue.root(of: held).appending(path: "one.txt").path(percentEncoded: false)))
        #expect(try Self.record(held).entries.map(\.name) == ["one.txt", "two.txt", "three.txt"])

        try queue.claim("c")
        let again = CopyLog()
        try await queue.apply("c") { source, _, _, _ in again.append(source.lastPathComponent) }
        #expect(again.calls == ["one.txt", "two.txt", "three.txt"])
        queue.release("c")
        #expect(!queue.holds("c"))
        #expect(Self.names(in: queue.directory.appending(path: "pending/c")).isEmpty)
    }

    @Test("an upload whose last entry cannot be recorded as in stays whole; the next start copies it in again and removes it")
    func lastEntryNotRecorded() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let queue = PendingCopyQueue(appRoot: f.root)
        let name = try Self.hold(queue, "c", [("one.txt", "1"), ("two.txt", "2")])
        try queue.claim("c")
        let taken = queue.directory.appending(path: "applying/c/\(name)")
        Self.setMode(0o500, taken)
        defer { Self.setMode(0o700, taken) }
        let log = CopyLog()
        try await queue.apply("c") { source, _, _, _ in log.append(source.lastPathComponent) }
        #expect(log.calls == ["one.txt", "two.txt"])
        Self.setMode(0o700, taken)
        queue.release("c")
        let held = queue.directory.appending(path: "pending/c/\(name)")
        for entry in ["one.txt", "two.txt"] {
            #expect(FileManager.default.fileExists(atPath: PendingCopyQueue.root(of: held).appending(path: entry).path(percentEncoded: false)))
        }
        #expect(try Self.record(held).entries.map(\.name) == ["one.txt", "two.txt"])

        try queue.claim("c")
        let again = CopyLog()
        try await queue.apply("c") { source, _, _, _ in again.append(source.lastPathComponent) }
        #expect(again.calls == ["one.txt", "two.txt"])
        queue.release("c")
        #expect(!queue.holds("c"))
        #expect(Self.names(in: queue.directory.appending(path: "pending/c")).isEmpty)
    }

    static func eventually(within time: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: time)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
