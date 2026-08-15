//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct OwnerWatchdogTest {
    private let log = Logger(label: "test")

    /// Liveness is answered by a stub rather than by real pids, so the timings below are the
    /// watchdog's own and not a race against a process the test would have to spawn.
    private func watchdog(
        now: ContinuousClock.Instant,
        alive: @escaping @Sendable (pid_t) -> Bool
    ) -> OwnerWatchdog {
        OwnerWatchdog(now: now, isAlive: alive, log: log)
    }

    @Test func liveOwnerKeepsTheEngineUp() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start) { _ in true }
        await subject.attach(pid: 42)
        // Well past both graces: a live owner renews the deadline on every tick, so no amount
        // of elapsed time on its own expires the engine.
        #expect(await subject.tick(now: start.advanced(by: .seconds(600))) == false)
        #expect(await subject.isOwned())
    }

    @Test func deadOwnerExpiresOnlyAfterTheGrace() async {
        let start = ContinuousClock.now
        let alive = Alive()
        let subject = watchdog(now: start) { _ in alive.value }
        await subject.attach(pid: 42)
        _ = await subject.tick(now: start)

        alive.value = false
        // Noticing the death does not end the grace: a relaunch still has it to re-attach in.
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))) == false)
        #expect(await subject.isOwned() == false)

        // The grace is counted from the last tick that saw the owner alive, not from the one
        // that noticed it gone — those are a single poll apart, and dating it from the last
        // sighting is what keeps a missed poll from extending the engine's life.
        #expect(await subject.tick(now: start.advanced(by: .seconds(29))) == false)
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceAfterOwnerLoss)))
    }

    @Test func relaunchWithinTheGraceKeepsTheSameEngine() async {
        let start = ContinuousClock.now
        let alive = Alive()
        let subject = watchdog(now: start) { pid in pid == 43 ? true : alive.value }
        await subject.attach(pid: 42)
        _ = await subject.tick(now: start)

        alive.value = false
        _ = await subject.tick(now: start.advanced(by: .seconds(1)))
        // The relaunched app pings with its new pid, which is what cancels the countdown.
        await subject.attach(pid: 43)
        #expect(await subject.tick(now: start.advanced(by: .seconds(120))) == false)
        #expect(await subject.isOwned())
    }

    @Test func engineNobodyClaimsExits() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start) { _ in true }
        // The CLI-demand-start case: launchd started the engine, no app ever claimed it.
        #expect(await subject.isOwned() == false)
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))) == false)
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceBeforeFirstOwner)))
    }

    @Test func expiryIsFinal() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start) { _ in true }
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceBeforeFirstOwner)))
        // The engine is already tearing down by now, so a late claim must not revive it into
        // serving requests it is about to drop.
        await subject.attach(pid: 42)
        #expect(await subject.isOwned() == false)
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))))
    }

    @Test func aClaimOfZeroIsIgnored() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start) { _ in true }
        // What an absent key decodes to, which is how a CLI ping looks.
        await subject.attach(pid: 0)
        #expect(await subject.isOwned() == false)
    }
}

/// Mutable liveness shared with the `@Sendable` stub above.
private final class Alive: @unchecked Sendable {
    var value = true
}
