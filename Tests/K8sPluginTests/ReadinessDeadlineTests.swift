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

@testable import ContainerK8s

private final class ReadinessClock: Sendable {
    let instant = Mutex(ContinuousClock.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

struct ReadinessDeadlineTests {
    private let log = Logger(label: "readiness-deadline-tests")

    @Test("late replies cannot succeed or delay the named timeout", arguments: [false, true], [Int32(0), Int32(1)])
    func lateReply(pods: Bool, code: Int32) async {
        let clock = ReadinessClock()
        do {
            try await K8sHelper.waitForReady(containerId: "fixture", log: log, now: { clock.now() }, sleep: { clock.advance($0) }) { arguments, deadline in
                if pods && arguments.contains("node") { return 0 }
                #expect(deadline == clock.now().advanced(by: .seconds(300)))
                clock.advance(.seconds(301))
                return code
            }
            Issue.record("readiness accepted a reply outside its budget")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.description.contains(pods ? "CoreDNS" : "control-plane node"))
            #expect(error.description.contains(pods ? "get pods -n kube-system" : "get nodes -o wide"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test("CoreDNS restart uses the same deadline and cannot prolong readiness")
    func healDeadline() async {
        let clock = ReadinessClock()
        let heals = Mutex(0)
        var timing = K8sHelper.ReadinessTiming()
        timing.retry = .seconds(120)
        do {
            try await K8sHelper.waitForReady(containerId: "fixture", log: log, timing: timing, now: { clock.now() }, sleep: { clock.advance($0) }) { arguments, deadline in
                if arguments.contains("node") { return 0 }
                if arguments.contains("restart") {
                    heals.withLock { $0 += 1 }
                    #expect(clock.now().duration(to: deadline) == .seconds(180))
                    clock.advance(.seconds(181))
                    return 0
                }
                return 1
            }
            Issue.record("a late heal bypassed the CoreDNS deadline")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.description.contains("CoreDNS"))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(heals.withLock { $0 } == 1)
    }

    @Test("a failing CoreDNS restart is attempted only once and retries stop at the budget")
    func oneHealAndBoundedSleep() async {
        let clock = ReadinessClock()
        let start = clock.now()
        let heals = Mutex(0)
        var timing = K8sHelper.ReadinessTiming()
        timing.retry = .seconds(120)
        await #expect(throws: ContainerizationError.self) {
            try await K8sHelper.waitForReady(containerId: "fixture", log: log, timing: timing, now: { clock.now() }, sleep: { clock.advance($0) }) { arguments, _ in
                if arguments.contains("node") { return 0 }
                if arguments.contains("restart") { heals.withLock { $0 += 1 } }
                return 1
            }
        }
        #expect(heals.withLock { $0 } == 1)
        #expect(start.duration(to: clock.now()) == .seconds(300))
    }

    @Test("on-time node and CoreDNS responses complete without a heal")
    func success() async throws {
        let clock = ReadinessClock()
        let calls = Mutex(0)
        try await K8sHelper.waitForReady(containerId: "fixture", log: log, now: { clock.now() }, sleep: { clock.advance($0) }) { arguments, deadline in
            #expect(!arguments.contains("restart"))
            #expect(deadline == clock.now().advanced(by: .seconds(300)))
            calls.withLock { $0 += 1 }
            clock.advance(.seconds(1))
            return 0
        }
        #expect(calls.withLock { $0 } == 2)
    }
}
