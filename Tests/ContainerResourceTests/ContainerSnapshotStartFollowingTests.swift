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

@testable import ContainerResource

/// A followed log's cursor is placed while the container is in the run it follows, so the next
/// run's log, which the engine starts again in place, is never read as this run's.
struct ContainerSnapshotStartFollowingTests {
    typealias Run = ContainerSnapshotRunTests

    /// Runs `startFollowing` from `first`, with `looks` as what each look at the container
    /// finds. The cursor is the number of the `start` that placed it.
    static func follow(_ first: ContainerSnapshot?, looks: [ContainerSnapshot?]) async throws -> (
        run: ContainerSnapshot?, cursor: Int, looked: Int
    ) {
        var looked = 0
        var started = 0
        let (run, cursor) = try await ContainerSnapshot.startFollowing(
            first,
            look: {
                defer { looked += 1 }
                return looks[min(looked, looks.count - 1)]
            }
        ) {
            started += 1
            return started
        }
        return (run, cursor, looked)
    }

    @Test("a run still going after the cursor is placed is the one followed")
    func sameRun() async throws {
        let run = Run.snapshot(.running)
        let result = try await Self.follow(run, looks: [Run.snapshot(.running)])
        #expect(result.run?.startedDate == run.startedDate)
        #expect(result.cursor == 1)
        #expect(result.looked == 1)
    }

    @Test("a run that restarted before the cursor was placed is not followed as the old run: the new one is, from a cursor placed in it")
    func restartedBetween() async throws {
        let next = Run.snapshot(.running, started: Run.started.addingTimeInterval(5))
        let result = try await Self.follow(Run.snapshot(.running), looks: [next, next])
        #expect(result.run?.startedDate == next.startedDate)
        #expect(result.cursor == 2)
        #expect(result.looked == 2)
    }

    @Test("a container not running, or stopped before the cursor was placed, or deleted, is not followed")
    func notFollowed() async throws {
        let stopped = try await Self.follow(Run.snapshot(.stopped), looks: [nil])
        #expect(stopped.run == nil && stopped.cursor == 1 && stopped.looked == 0)
        let none = try await Self.follow(nil, looks: [nil])
        #expect(none.run == nil && none.cursor == 1 && none.looked == 0)
        for after in [Run.snapshot(.restarting), Run.snapshot(.stopped), nil] {
            let ended = try await Self.follow(Run.snapshot(.running), looks: [after])
            #expect(ended.run == nil)
            // Placed again after the look, on what the log holds now.
            #expect(ended.cursor == 2)
        }
    }

    @Test("a container whose runs keep changing is not followed")
    func keepsChanging() async throws {
        let looks = (1...5).map { Run.snapshot(.running, started: Run.started.addingTimeInterval(Double($0))) }
        let result = try await Self.follow(Run.snapshot(.running), looks: looks)
        #expect(result.run == nil)
        #expect(result.looked == 3)
    }
}
