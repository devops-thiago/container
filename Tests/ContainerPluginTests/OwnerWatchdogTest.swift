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

@testable import ContainerPlugin

struct OwnerWatchdogTest {
    private let log = Logger(label: "test")

    /// The app's presence is answered by a stub rather than by a real app, so the timings below
    /// are the watchdog's own and not a race against a process the test would have to launch.
    private func watchdog(
        now: ContinuousClock.Instant,
        running: Running
    ) -> OwnerWatchdog {
        OwnerWatchdog(now: now, appIsRunning: { running.value }, log: log)
    }

    @Test func aRunningAppKeepsTheServiceUp() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start, running: Running(true))
        _ = await subject.tick(now: start)
        // Well past both graces: a running app renews the deadline on every tick, so elapsed
        // time alone never expires the service.
        #expect(await subject.tick(now: start.advanced(by: .seconds(600))) == false)
        #expect(await subject.isOwned())
    }

    @Test func aClosedAppExpiresOnlyAfterTheGrace() async {
        let start = ContinuousClock.now
        let running = Running(true)
        let subject = watchdog(now: start, running: running)
        _ = await subject.tick(now: start)

        running.value = false
        // Noticing the app is gone does not end the grace: a relaunch still has it to return in.
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))) == false)
        // And the service keeps working through it. The reprieve exists so the relaunched app
        // finds its containers still running; one that refused everything meanwhile would be up
        // in name only.
        #expect(await subject.isOwned())

        // The grace runs from the last tick that saw the app, not from the one that noticed it
        // gone — those are a single poll apart, and dating it from the last sighting is what
        // keeps a missed poll from extending the service's life.
        #expect(await subject.tick(now: start.advanced(by: .seconds(29))) == false)
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceAfterOwnerLoss)))
    }

    @Test func aRelaunchWithinTheGraceKeepsTheSameService() async {
        let start = ContinuousClock.now
        let running = Running(true)
        let subject = watchdog(now: start, running: running)
        _ = await subject.tick(now: start)

        running.value = false
        _ = await subject.tick(now: start.advanced(by: .seconds(1)))
        running.value = true
        #expect(await subject.tick(now: start.advanced(by: .seconds(2))) == false)
        // Back to a full grace from the moment it returned, not the remainder of the old one.
        #expect(await subject.tick(now: start.advanced(by: .seconds(120))) == false)
        #expect(await subject.isOwned())
    }

    @Test func aServiceThatNeverSeesAnAppExits() async {
        let start = ContinuousClock.now
        let subject = watchdog(now: start, running: Running(false))
        // The CLI-demand-start case: launchd started the service, no app is running.
        #expect(await subject.isOwned() == false)
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))) == false)
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceBeforeFirstOwner)))
    }

    @Test func aClosedAppPastTheGraceStopsServing() async {
        let start = ContinuousClock.now
        let running = Running(true)
        let subject = watchdog(now: start, running: running)
        _ = await subject.tick(now: start)
        running.value = false
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceAfterOwnerLoss)))
        #expect(await subject.isOwned() == false)
    }

    @Test func expiryIsFinal() async {
        let start = ContinuousClock.now
        let running = Running(false)
        let subject = watchdog(now: start, running: running)
        #expect(await subject.tick(now: start.advanced(by: OwnerWatchdog.graceBeforeFirstOwner)))
        // The service is already tearing down by now, so an app appearing late must not revive
        // it into serving requests it is about to drop.
        running.value = true
        #expect(await subject.isOwned() == false)
        #expect(await subject.tick(now: start.advanced(by: .seconds(1))))
    }
}

/// Mutable presence shared with the `@Sendable` probe above.
private final class Running: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
