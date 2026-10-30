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

import ContainerizationError
import Foundation
import Logging
import Synchronization
import Testing

@testable import ContainerCluster

struct RegisteredNodeReadinessTests {
    private let log = Logger(label: "registration-tests")

    @Test func registrationChecksEveryNamedNodeWithoutReadyOrCoreDNSConditions() async throws {
        let instant = Mutex(ContinuousClock.now)
        let calls = Mutex(0)
        try await ClusterHelper.waitForRegisteredNodes(
            containerId: "dev", nodes: ["dev", "dev-worker-1"], log: log,
            now: { instant.withLock { $0 } }, sleep: { duration in instant.withLock { $0 = $0.advanced(by: duration) } }
        ) { arguments, _ in
            #expect(arguments == ["get", "node/dev", "node/dev-worker-1", "--request-timeout=2s"])
            return calls.withLock { count in
                count += 1
                return count == 1 ? Int32(1) : Int32(0)
            }
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func lateRegistrationReplyCannotPassOrExtendTheBudget(code: Int32) async {
        let instant = Mutex(ContinuousClock.now)
        do {
            try await ClusterHelper.waitForRegisteredNodes(
                containerId: "dev", nodes: ["dev", "dev-worker-1"], log: log, budget: .seconds(3),
                now: { instant.withLock { $0 } }, sleep: { _ in Issue.record("late reply should fail before sleeping") }
            ) { _, deadline in
                instant.withLock { $0 = deadline.advanced(by: .seconds(1)) }
                return code
            }
            Issue.record("late registration reply was accepted")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.description.contains("expected nodes"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test func startOptionsKeepPolicyChoiceSeparateFromAdoption() throws {
        let selected = try ClusterStart.parse(["--name", "dev", "--readiness", "registered"])
        #expect(selected.readiness == .registered)
        #expect(!selected.adoptLegacy)
        #expect(try ClusterStart.parse([]).readiness == nil)
        #expect(throws: (any Error).self) { try ClusterStart.parse(["--readiness", "NotReady"]) }
        let adopted = try ClusterStart.parse(["--adopt-legacy", "--readiness", "ready"])
        #expect(adopted.readiness == .ready)
        #expect(adopted.adoptLegacy)
    }
}
