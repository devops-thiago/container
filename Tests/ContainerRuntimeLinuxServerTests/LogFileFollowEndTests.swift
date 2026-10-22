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
import Foundation
import Synchronization
import Testing

/// `container logs -f` ends with its container's run, as `docker logs -f` does, and sends the
/// last output first.
@Suite("A followed log ends with its run", .timeLimit(.minutes(1)))
struct LogFileFollowEndTests {
    final class Fixture: @unchecked Sendable {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path: URL
        let received = Mutex(Data())
        init() throws {
            path = directory.appendingPathComponent("stdio.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: Data("before the follow\n".utf8))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        /// Rewrites the file from the start with `text`, as the engine does at a rollover and
        /// at the next run's start.
        func rewrite(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
        }

        /// What the follower sent, without the lines `started` wrote.
        var text: String {
            received.withLock { String(decoding: $0, as: UTF8.self) }.replacingOccurrences(of: "ready\n", with: "")
        }

        /// Writes a line until the follower has sent one: the follow has begun, and reads what
        /// is written from here on. The follower starts at the end of the file whenever its task
        /// runs, so what is written before that is not a test of it.
        func started() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while received.withLock({ $0.isEmpty }) && ContinuousClock.now < deadline {
                try append("ready\n")
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!received.withLock { $0.isEmpty })
        }

        /// Waits for the follower to have sent `text`.
        func waitFor(_ text: String) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !self.text.contains(text) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(self.text.contains(text))
        }
    }

    /// Waits for `follow` to return. A follow that never does is cancelled with the test when
    /// its time is up, rather than holding the run open.
    static func ended(_ follow: Task<Void, any Error>) async throws {
        try await withTaskCancellationHandler {
            try await follow.value
        } onCancel: {
            follow.cancel()
        }
    }

    @Test("the follow ends once the run has ended, after what the container wrote last")
    func endsWithTheRun() async throws {
        let fixture = try Fixture()
        let ended = Mutex(false)
        let asked = Mutex(0)
        let handle = try FileHandle(forReadingFrom: fixture.path)
        let follow = Task { [fixture] in
            try await LogFileFollow.follow(
                handle, statusInterval: .milliseconds(30),
                runEnded: {
                    asked.withLock { $0 += 1 }
                    return ended.withLock { $0 }
                }
            ) { data in fixture.received.withLock { $0.append(data) } }
        }
        try await fixture.started()
        try fixture.append("running\n")
        try await fixture.waitFor("running\n")
        // Control: while the run goes on, the follow is asked about it and keeps going.
        let before = asked.withLock { $0 }
        while asked.withLock({ $0 }) < before + 2 { try await Task.sleep(for: .milliseconds(10)) }
        // The last output, and then the exit, with no change to the file after it.
        try fixture.append("last words\n")
        ended.withLock { $0 = true }
        try await Self.ended(follow)
        #expect(fixture.text == "running\nlast words\n")
    }

    @Test("the follow ends at once when its log is deleted with the container, after what was left in it")
    func endsWhenDeleted() async throws {
        let fixture = try Fixture()
        let handle = try FileHandle(forReadingFrom: fixture.path)
        // The run is never seen to end, and not asked about for an hour: only the deletion
        // can end this follow.
        let follow = Task { [fixture] in
            try await LogFileFollow.follow(handle, statusInterval: .seconds(3600), runEnded: { false }) { data in
                fixture.received.withLock { $0.append(data) }
            }
        }
        try await fixture.started()
        try fixture.append("running\n")
        try await fixture.waitFor("running\n")
        try fixture.append("final\n")
        try FileManager.default.removeItem(at: fixture.path)
        try await Self.ended(follow)
        #expect(fixture.text == "running\nfinal\n")
    }

    @Test("a log rewritten by the container's next run is not read once its run has ended; a rollover in the run is")
    func nextRunIsNotRead() async throws {
        let fixture = try Fixture()
        let ended = Mutex(false)
        let handle = try FileHandle(forReadingFrom: fixture.path)
        // Not asked about for an hour: only the rewrite makes the follow ask.
        let follow = Task { [fixture] in
            try await LogFileFollow.follow(handle, statusInterval: .seconds(3600), runEnded: { ended.withLock { $0 } }) { data in
                fixture.received.withLock { $0.append(data) }
            }
        }
        try await fixture.started()
        try fixture.append("first run\n")
        try await fixture.waitFor("first run\n")
        // Control: the engine's rollover of a full log, in the same run, is read on.
        try fixture.rewrite("[container log rolled over]\nrolled\n")
        try await fixture.waitFor("rolled\n")
        // The exit, then the restart's new log.
        ended.withLock { $0 = true }
        try fixture.rewrite("second run\n")
        try await Self.ended(follow)
        #expect(fixture.text == "first run\n[container log rolled over]\nrolled\n")
    }
}
