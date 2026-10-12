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

/// The exit of a container removed when it stopped, kept for a wait that arrives after it.
struct RemovedExitsTests {
    @Test("a recorded exit is found by its container")
    func recordedExitIsFound() {
        var exits = RemovedExits()
        exits.record(ExitStatus(exitCode: 3), for: "web")
        #expect(exits.status(for: "web")?.exitCode == 3)
        #expect(exits.status(for: "db") == nil)
    }

    @Test("a container that exits again replaces its earlier exit")
    func laterExitReplaces() {
        var exits = RemovedExits()
        exits.record(ExitStatus(exitCode: 1), for: "web")
        exits.record(ExitStatus(exitCode: 0), for: "web")
        #expect(exits.status(for: "web")?.exitCode == 0)
        #expect(exits.entries.count == 1)
    }

    @Test("only the newest exits are kept")
    func boundedToTheNewest() {
        var exits = RemovedExits(capacity: 2)
        exits.record(ExitStatus(exitCode: 1), for: "a")
        exits.record(ExitStatus(exitCode: 2), for: "b")
        exits.record(ExitStatus(exitCode: 3), for: "c")
        #expect(exits.status(for: "a") == nil)
        #expect(exits.status(for: "b")?.exitCode == 2)
        #expect(exits.status(for: "c")?.exitCode == 3)
    }
}
