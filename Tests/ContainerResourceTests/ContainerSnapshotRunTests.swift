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

/// Which later look at a container still shows the run a followed log began in.
struct ContainerSnapshotRunTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func snapshot(_ status: RuntimeStatus, started: Date? = started, incarnation: String = "one") -> ContainerSnapshot {
        ContainerSnapshot(
            configuration: makeTestConfiguration(id: "web"), incarnation: incarnation, status: status, networks: [], startedDate: started)
    }

    @Test("the same run goes on while the container runs or is being stopped")
    func sameRun() {
        let run = Self.snapshot(.running)
        #expect(Self.snapshot(.running).isInRun(of: run))
        #expect(Self.snapshot(.stopping).isInRun(of: run))
    }

    @Test("the run is over once the container has stopped, waits to restart, started again, or was made again")
    func runOver() {
        let run = Self.snapshot(.running)
        #expect(!Self.snapshot(.stopped).isInRun(of: run))
        #expect(!Self.snapshot(.restarting).isInRun(of: run))
        #expect(!Self.snapshot(.running, started: Self.started.addingTimeInterval(1)).isInRun(of: run))
        #expect(!Self.snapshot(.running, incarnation: "two").isInRun(of: run))
    }

    @Test("a container that was not running when the follow began has no run to follow")
    func noRun() {
        for status in [RuntimeStatus.stopped, .restarting, .unknown] {
            let run = Self.snapshot(status)
            #expect(!run.hasLiveProcess)
            #expect(!Self.snapshot(.running).isInRun(of: run))
        }
    }
}
