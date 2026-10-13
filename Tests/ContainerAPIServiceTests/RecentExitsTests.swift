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

import Containerization
import Foundation
import Testing

@testable import ContainerAPIService

/// The last exit of a stopped container, kept for a wait that arrives after it. Each case
/// drives the cache through the calls `ContainersService` makes: `record` when a run's exit is
/// handled, `forget` when a container is created or a new run starts, and `lateExit` from
/// `wait` with what it knows about the container now.
struct RecentExitsTests {
    let start = ContinuousClock.now

    func stopped(_ incarnation: String) -> RecentExits.Current {
        RecentExits.Current(incarnation: incarnation, isStopped: true)
    }

    @Test("a stopped container's wait gets the exit of its own run")
    func stoppedContainerGetsItsExit() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: stopped("one"), at: start)?.exitCode == 3)
        #expect(exits.lateExit(for: "db", current: stopped("one"), at: start) == nil)
    }

    @Test("a container removed after its exit (--rm) still answers with it")
    func removedContainerAnswers() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 0), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: nil, at: start + .seconds(1))?.exitCode == 0)
    }

    @Test("a running container is asked, not answered from the cache")
    func runningContainerIsAsked() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        let running = RecentExits.Current(incarnation: "one", isStopped: false)
        #expect(exits.lateExit(for: "web", current: running, at: start) == nil)
    }

    @Test("a new container with a removed one's name never gets the removed one's exit")
    func replacementByNameGetsNothing() {
        var exits = RecentExits()
        // web exits 3 and is removed; a new web is created and has not run.
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        exits.forget("web")
        #expect(exits.lateExit(for: "web", current: stopped("two"), at: start) == nil)
        // Removed again before it ever ran: still nothing of the first one's.
        #expect(exits.lateExit(for: "web", current: nil, at: start) == nil)
        // Its own run's exit is its answer.
        exits.record(ExitStatus(exitCode: 0), for: "web", incarnation: "two", at: start)
        #expect(exits.lateExit(for: "web", current: stopped("two"), at: start)?.exitCode == 0)
    }

    @Test("an exit kept for another incarnation is not answered, even without a create seen")
    func otherIncarnationGetsNothing() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: stopped("two"), at: start) == nil)
    }

    @Test("a new run of the same container drops the last run's exit")
    func newRunDropsTheLastExit() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        exits.forget("web")
        #expect(exits.lateExit(for: "web", current: stopped("one"), at: start) == nil)
        exits.record(ExitStatus(exitCode: 5), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: stopped("one"), at: start)?.exitCode == 5)
    }

    @Test("an exit is answered only for a short while")
    func exitsExpire() {
        var exits = RecentExits(lifetime: .seconds(60))
        exits.record(ExitStatus(exitCode: 3), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: nil, at: start + .seconds(60))?.exitCode == 3)
        #expect(exits.lateExit(for: "web", current: nil, at: start + .seconds(61)) == nil)
        #expect(exits.lateExit(for: "web", current: stopped("one"), at: start + .seconds(61)) == nil)
    }

    @Test("a container that exits again replaces its earlier exit")
    func laterExitReplaces() {
        var exits = RecentExits()
        exits.record(ExitStatus(exitCode: 1), for: "web", incarnation: "one", at: start)
        exits.record(ExitStatus(exitCode: 0), for: "web", incarnation: "one", at: start)
        #expect(exits.lateExit(for: "web", current: stopped("one"), at: start)?.exitCode == 0)
        #expect(exits.entries.count == 1)
    }

    @Test("only the newest exits are kept")
    func boundedToTheNewest() {
        var exits = RecentExits(capacity: 2)
        exits.record(ExitStatus(exitCode: 1), for: "a", incarnation: "a1", at: start)
        exits.record(ExitStatus(exitCode: 2), for: "b", incarnation: "b1", at: start)
        exits.record(ExitStatus(exitCode: 3), for: "c", incarnation: "c1", at: start)
        #expect(exits.lateExit(for: "a", current: nil, at: start) == nil)
        #expect(exits.lateExit(for: "b", current: nil, at: start)?.exitCode == 2)
        #expect(exits.lateExit(for: "c", current: nil, at: start)?.exitCode == 3)
    }
}
