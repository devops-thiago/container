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

import ContainerLog
import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

@Suite("Bounded runtime logs")
struct BoundedLogWriterTests {
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path: URL
        init() throws {
            path = directory.appendingPathComponent("stdio.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func handle() throws -> FileHandle { try FileHandle(forWritingTo: path) }
        func data() throws -> Data { try Data(contentsOf: path) }
    }

    @Test func detachedOutputStaysWithinBudget() throws {
        let fixture = try Fixture()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        let output = MultiWriter(handles: [], log: log)
        defer { try? output.close() }
        for index in 0..<2_000 {
            let line = Data("detached output \(index)\n".utf8)
            try output.write(line)
            let data = try fixture.data()
            #expect(data.count <= 256)
            #expect(data.suffix(line.count) == line)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["stdio.log"])
    }

    @Test func oneOversizedWriteKeepsRecentTail() throws {
        let fixture = try Fixture()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        defer { try? log.close() }
        let data = Data((String(repeating: "old", count: 10_000) + "RECENT\n").utf8)
        try log.write(data)
        let stored = try fixture.data()
        #expect(stored.count == 256)
        #expect(String(decoding: stored, as: UTF8.self).hasPrefix(BoundedLogWriter.markerPrefix))
        #expect(stored.suffix(7) == Data("RECENT\n".utf8))
    }

    @Test func stdoutAndStderrShareBudgetAndPreserveAttachments() async throws {
        let fixture = try Fixture()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 512)
        let paths = ["stdout", "stderr"].map { fixture.directory.appendingPathComponent($0) }
        for path in paths { FileManager.default.createFile(atPath: path.path, contents: nil) }
        let outputs = try paths.map { MultiWriter(handles: [try FileHandle(forWritingTo: $0)], log: log) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, output) in outputs.enumerated() {
                group.addTask {
                    for _ in 0..<1_000 { try output.write(Data("stream-\(index)\n".utf8)) }
                }
            }
            try await group.waitForAll()
        }
        for output in outputs { try output.close() }
        for (index, path) in paths.enumerated() {
            #expect(try Data(contentsOf: path) == Data(String(repeating: "stream-\(index)\n", count: 1_000).utf8))
        }
        let contents = String(decoding: try fixture.data(), as: UTF8.self)
        #expect(contents.utf8.count <= 512)
        for line in contents.split(separator: "\n").dropFirst() {
            #expect(line == "stream-0" || line == "stream-1")
        }
    }

    @Test func attachmentFailureDoesNotSuppressDiskLogs() throws {
        let fixture = try Fixture()
        let attachment = try fixture.handle()
        try attachment.close()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        defer { try? log.close() }
        let output = MultiWriter(handles: [attachment], log: log)
        #expect(throws: (any Error).self) { try output.write(Data("retained\n".utf8)) }
        #expect(try fixture.data() == Data("retained\n".utf8))
    }

    @Test func diskFullIsReportedOnceWithoutRetryAndAttachmentContinues() throws {
        let fixture = try Fixture()
        let calls = Mutex(0)
        let reports = Mutex(0)
        var operations = BoundedLogWriter.Operations()
        operations.write = { _, _ in
            calls.withLock { $0 += 1 }
            throw POSIXError(.ENOSPC)
        }
        let log = try BoundedLogWriter(
            handle: fixture.handle(), maximumBytes: 256, operations: operations,
            onFailure: { error in
                #expect((error as? POSIXError)?.code == .ENOSPC)
                reports.withLock { $0 += 1 }
            })
        defer { try? log.close() }
        #expect(throws: POSIXError(.ENOSPC)) { try log.write(Data("first".utf8)) }
        #expect(throws: POSIXError(.ENOSPC)) { try log.write(Data("second".utf8)) }
        let attachedPath = fixture.directory.appendingPathComponent("attached")
        FileManager.default.createFile(atPath: attachedPath.path, contents: nil)
        let attached = try FileHandle(forWritingTo: attachedPath)
        let output = MultiWriter(handles: [attached], log: log)
        for _ in 0..<100 { try output.write(Data("attached\n".utf8)) }
        try output.close()
        #expect(try Data(contentsOf: attachedPath) == Data(String(repeating: "attached\n", count: 100).utf8))
        #expect(calls.withLock { $0 } == 1)
        #expect(reports.withLock { $0 } == 1)
        #expect(try fixture.data().isEmpty)
    }

    @Test func failedRolloverPreservesBoundAndStopsRetrying() throws {
        let fixture = try Fixture()
        let calls = Mutex(0)
        var operations = BoundedLogWriter.Operations()
        operations.truncate = { _ in
            calls.withLock { $0 += 1 }
            throw POSIXError(.EACCES)
        }
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256, operations: operations)
        defer { try? log.close() }
        let original = Data(repeating: 65, count: 256)
        try log.write(original)
        for _ in 0..<10 {
            #expect(throws: POSIXError(.EACCES)) { try log.write(Data([66])) }
        }
        #expect(try fixture.data() == original)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func partialDiskWriteFailureDoesNotRetryOrExceedBudget() throws {
        let fixture = try Fixture()
        var operations = BoundedLogWriter.Operations()
        operations.write = { handle, data in
            try handle.write(contentsOf: data.prefix(7))
            throw POSIXError(.ENOSPC)
        }
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256, operations: operations)
        defer { try? log.close() }
        for _ in 0..<10 {
            #expect(throws: POSIXError(.ENOSPC)) { try log.write(Data(repeating: 65, count: 512)) }
        }
        #expect(try fixture.data().count == 7)
    }

    @Test func sameSizeRolloversAndReconnectionAreVisibleToDescriptorReader() throws {
        let fixture = try Fixture()
        let handle = try FileHandle(forReadingFrom: fixture.path)
        defer { try? handle.close() }
        var reader = try LogFileReader(handle: handle)
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        defer { try? log.close() }
        var previous = Data()
        for _ in 0..<10 {
            try log.write(Data(repeating: 65, count: 512))
            let current = try reader.nextChunk()
            #expect(current.count == 256)
            #expect(current != previous)
            #expect(try reader.nextChunk().isEmpty)
            previous = current
        }
        let reconnect = try FileHandle(forReadingFrom: fixture.path)
        defer { try? reconnect.close() }
        var freshReader = try LogFileReader(handle: reconnect)
        #expect(try freshReader.nextChunk() == previous)
    }

    @Test func restartTruncationIsVisibleAndNewWriterGetsFreshBudget() throws {
        let fixture = try Fixture()
        let handle = try FileHandle(forReadingFrom: fixture.path)
        defer { try? handle.close() }
        var reader = try LogFileReader(handle: handle)
        let oldLog = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        try oldLog.write(Data(repeating: 65, count: 256))
        #expect(try reader.nextChunk().count == 256)
        try oldLog.close()
        let restartHandle = try fixture.handle()
        try restartHandle.truncate(atOffset: 0)
        let newLog = try BoundedLogWriter(handle: restartHandle, maximumBytes: 256)
        defer { try? newLog.close() }
        try newLog.write(Data("restarted\n".utf8))
        #expect(try reader.nextChunk() == Data("restarted\n".utf8))
        try newLog.write(Data(repeating: 66, count: 512))
        #expect(try reader.nextChunk().count == 256)
    }

    @Test func followerReceivesRolloverAndStopsOnCancellation() async throws {
        let fixture = try Fixture()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        defer { try? log.close() }
        let received = Mutex(Data())
        let handle = try FileHandle(forReadingFrom: fixture.path)
        let follow = Task {
            try await LogFileFollow.follow(handle) { data in received.withLock { $0.append(data) } }
        }
        defer { follow.cancel() }
        // Wait for actual delivery, not an assumed dispatch-source startup delay.
        let deadline = ContinuousClock.now + .seconds(5)
        while received.withLock({ $0.isEmpty }) && ContinuousClock.now < deadline {
            try log.write(Data("ready\n".utf8))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!received.withLock { $0.isEmpty })
        for index in 0..<3 {
            let token = "follower-\(index)\n"
            try log.write(Data((String(repeating: "filler\n", count: 100) + token).utf8))
            let until = ContinuousClock.now + .seconds(5)
            while !received.withLock({ String(decoding: $0, as: UTF8.self).contains(token) })
                && ContinuousClock.now < until
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(received.withLock { String(decoding: $0, as: UTF8.self).contains(token) })
        }
        follow.cancel()
        try await follow.value
    }

    @Test func readerRejectsUnreadableDescriptors() throws {
        let fixture = try Fixture()
        let handle = try fixture.handle()
        defer { try? handle.close() }
        #expect(throws: POSIXError(.EBADF)) { try LogFileReader(handle: handle) }
    }

    @Test func closedWriterFailsAndInvalidBudgetRejected() throws {
        let fixture = try Fixture()
        let handle = try fixture.handle()
        #expect(throws: POSIXError(.EINVAL)) { try BoundedLogWriter(handle: handle, maximumBytes: 1) }
        try handle.close()
        let log = try BoundedLogWriter(handle: fixture.handle(), maximumBytes: 256)
        try log.write(Data())
        try log.close()
        try log.close()
        #expect(throws: POSIXError(.EBADF)) { try log.write(Data([1])) }
    }
}
