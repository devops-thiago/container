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

@testable import ContainerRuntimeLinuxServer

/// How the runtime reads Docker's `OOMKilled` from the container's cgroup as a run ends.
struct OOMKillReportTests {
    @Test("any OOM kill in the cgroup, created for this run, is an OOM kill of this run")
    func countToFlag() {
        #expect(!RuntimeService.wasOOMKilled(oomKillEvents: 0))
        #expect(RuntimeService.wasOOMKilled(oomKillEvents: 1))
        #expect(RuntimeService.wasOOMKilled(oomKillEvents: 42))
    }

    @Test("a read that answers in time gives its answer")
    func answersInTime() async {
        let value = await RuntimeService.firstOf(seconds: 5) { 7 }
        #expect(value == 7)
    }

    @Test("a read that does not answer gives nil at the deadline, without being awaited")
    func boundedWhenStuck() async {
        let clock = ContinuousClock()
        let started = clock.now
        let value: Int? = await RuntimeService.firstOf(seconds: 1) {
            // A guest that does not answer: the read outlives the deadline.
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(value == nil)
        #expect(clock.now - started < .seconds(10))
    }
}
