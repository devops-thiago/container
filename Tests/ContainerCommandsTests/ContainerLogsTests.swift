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

struct ContainerLogsTests {
    /// `container logs -f` on a log that is still empty waits for the first output instead of
    /// returning, and passes on what is appended.
    @Test(.timeLimit(.minutes(1)))
    func followsInitiallyEmptyLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("container.log")
        try Data().write(to: logURL)
        let reader = try FileHandle(forReadingFrom: logURL)
        let writer = try FileHandle(forWritingTo: logURL)
        defer { try? writer.close() }

        let received = Mutex(Data())
        let follower = Task {
            try await LogFileFollow.follow(reader, from: try LogFileReader(handle: reader)) { data in
                received.withLock { $0.append(data) }
            }
        }
        defer { follower.cancel() }

        // The follow is still running on an empty log: it did not return early.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!follower.isCancelled)

        let expected = Data("hello\n".utf8)
        try writer.write(contentsOf: expected)
        let deadline = ContinuousClock.now + .seconds(10)
        while received.withLock({ $0 }) != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.withLock { $0 } == expected, "follow must pass on output appended to the empty log")
    }
}
