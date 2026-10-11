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

struct HealthCheckConfigurationTests {
    private let second: Int64 = 1_000_000_000

    @Test func theCommandIsTheTestWithoutItsKind() {
        #expect(HealthCheckConfiguration(test: ["CMD", "curl", "-f", "localhost"]).command == ["curl", "-f", "localhost"])
        #expect(HealthCheckConfiguration(test: ["CMD-SHELL", "pg_isready || exit 1"]).command == ["/bin/sh", "-c", "pg_isready || exit 1"])
        #expect(HealthCheckConfiguration(test: ["NONE"]).command == nil)
        #expect(HealthCheckConfiguration(test: []).command == nil)
        #expect(HealthCheckConfiguration(test: ["CMD"]).command == nil)
        #expect(HealthCheckConfiguration(test: ["SOMETHING", "else"]).command == nil, "a kind Docker does not know runs nothing")
    }

    @Test func unsetValuesAreDockersDefaults() {
        let check = HealthCheckConfiguration(test: ["CMD", "true"])
        #expect(check.effectiveInterval == .seconds(30))
        #expect(check.effectiveTimeout == .seconds(30))
        #expect(check.effectiveStartPeriod == .zero)
        #expect(check.effectiveStartInterval == .seconds(5))
        #expect(check.effectiveRetries == 3)
        let given = HealthCheckConfiguration(test: ["CMD", "true"], interval: 2 * second, timeout: second, startPeriod: 10 * second, startInterval: second, retries: 5)
        #expect(given.effectiveInterval == .seconds(2))
        #expect(given.effectiveTimeout == .seconds(1))
        #expect(given.effectiveStartPeriod == .seconds(10))
        #expect(given.effectiveStartInterval == .seconds(1))
        #expect(given.effectiveRetries == 5)
    }

    @Test func theFlagsGoOverTheImageFieldByField() {
        let image = HealthCheckConfiguration(test: ["CMD", "/healthz"], interval: 10 * second, timeout: 3 * second, retries: 5)
        // No flags: the image's check.
        #expect(HealthCheckConfiguration.resolve(user: nil, image: image) == image)
        // Timing only: the image's test, with the given interval and the rest the image's.
        #expect(
            HealthCheckConfiguration.resolve(user: HealthCheckConfiguration(interval: 2 * second), image: image)
                == HealthCheckConfiguration(test: ["CMD", "/healthz"], interval: 2 * second, timeout: 3 * second, retries: 5))
        // A command replaces the image's.
        #expect(
            HealthCheckConfiguration.resolve(user: HealthCheckConfiguration(test: ["CMD-SHELL", "true"]), image: image)?.test == ["CMD-SHELL", "true"])
        // --no-healthcheck turns it off.
        #expect(HealthCheckConfiguration.resolve(user: .disabled, image: image) == nil)
        // HEALTHCHECK NONE in the image, and nothing given: none.
        #expect(HealthCheckConfiguration.resolve(user: nil, image: .disabled) == nil)
        // Timing with no test anywhere: nothing to run.
        #expect(HealthCheckConfiguration.resolve(user: HealthCheckConfiguration(interval: second), image: nil) == nil)
        #expect(HealthCheckConfiguration.resolve(user: nil, image: nil) == nil)
        // A command on an image without a check.
        #expect(
            HealthCheckConfiguration.resolve(user: HealthCheckConfiguration(test: ["CMD-SHELL", "true"]), image: nil)
                == HealthCheckConfiguration(test: ["CMD-SHELL", "true"]))
    }

    @Test func dockersLimitsAreRefused() {
        #expect(throws: HealthCheckError.self) { try HealthCheckConfiguration(test: ["CMD", "true"], interval: 999_999).validate() }
        #expect(throws: HealthCheckError.self) { try HealthCheckConfiguration(test: ["CMD", "true"], timeout: -1).validate() }
        #expect(throws: HealthCheckError.self) { try HealthCheckConfiguration(test: ["CMD", "true"], retries: -1).validate() }
        #expect(throws: Never.self) { try HealthCheckConfiguration(test: ["CMD", "true"], interval: 1_000_000).validate() }
        #expect(throws: Never.self) { try HealthCheckConfiguration(test: ["CMD", "true"]).validate() }
    }

    @Test(arguments: [
        ("30s", Duration.seconds(30)), ("1m30s", .seconds(90)), ("500ms", .milliseconds(500)), ("1.5s", .milliseconds(1500)),
        ("2h", .seconds(7200)), ("0", .zero), ("1us", .microseconds(1)), ("10ns", .nanoseconds(10)), ("-2s", .seconds(-2)),
    ])
    func durationsAreReadAsGoReadsThem(_ text: String, _ expected: Duration) {
        #expect(HealthCheckConfiguration.parseDuration(text) == expected)
    }

    @Test(arguments: ["", "2", "s", "1x", "1.s.", "one second", "1d"])
    func notDurations(_ text: String) {
        #expect(HealthCheckConfiguration.parseDuration(text) == nil)
    }

    @Test func durationsAreWrittenAsDockerWritesThem() {
        #expect(HealthCheckConfiguration.format(.seconds(30)) == "30s")
        #expect(HealthCheckConfiguration.format(.seconds(90)) == "1m30s")
        #expect(HealthCheckConfiguration.format(.seconds(3600)) == "1h0m0s")
        #expect(HealthCheckConfiguration.format(.milliseconds(500)) == "500ms")
        #expect(HealthCheckConfiguration.format(.milliseconds(1500)) == "1.5s")
        #expect(HealthCheckConfiguration.format(.zero) == "0s")
    }

    @Test func aStoredConfigurationWithoutACheckStillLoads() throws {
        var config = makeTestConfiguration()
        let legacy = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ContainerConfiguration.self, from: legacy).healthCheck == nil)

        config.healthCheck = HealthCheckConfiguration(test: ["CMD-SHELL", "true"], interval: 2 * second)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: try JSONEncoder().encode(config))
        #expect(decoded.healthCheck == config.healthCheck)
        #expect(try JSONDecoder().decode(HealthCheckConfiguration.self, from: Data(#"{"test":["CMD","x"]}"#.utf8)).retries == 0)
    }
}

struct ContainerHealthTests {
    private let check = HealthCheckConfiguration(test: ["CMD", "true"], interval: 2_000_000_000, startPeriod: 10_000_000_000, retries: 2)

    private func result(_ exitCode: Int32, output: String = "") -> HealthCheckResult {
        HealthCheckResult(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), exitCode: exitCode, output: output)
    }

    @Test func aPassIsHealthyAndEndsTheStreak() {
        var health = ContainerHealth(status: .healthy, failingStreak: 1)
        let stillHealthy = health.record(result(0), sinceStart: .seconds(40), startPeriod: .zero, retries: 3)
        #expect(!stillHealthy)
        #expect(health.status == .healthy)
        #expect(health.failingStreak == 0)
        var starting = ContainerHealth()
        let nowHealthy = starting.record(result(0), sinceStart: .seconds(1), startPeriod: .seconds(10), retries: 3)
        #expect(nowHealthy)
        #expect(starting.status == .healthy)
    }

    @Test func retriesFailuresInARowAreUnhealthy() {
        var health = ContainerHealth()
        let firstFailure = health.record(result(1), sinceStart: .seconds(30), startPeriod: .zero, retries: 3)
        #expect(!firstFailure)
        #expect(health.status == .starting)
        #expect(health.failingStreak == 1)
        let secondFailure = health.record(result(1), sinceStart: .seconds(60), startPeriod: .zero, retries: 3)
        #expect(!secondFailure)
        let thirdFailure = health.record(result(1), sinceStart: .seconds(90), startPeriod: .zero, retries: 3)
        #expect(thirdFailure)
        #expect(health.status == .unhealthy)
        #expect(health.failingStreak == 3)
        let recovered = health.record(result(0), sinceStart: .seconds(120), startPeriod: .zero, retries: 3)
        #expect(recovered)
        #expect(health.status == .healthy)
    }

    @Test func aFailureShortOfRetriesLeavesAHealthyContainerHealthy() {
        var health = ContainerHealth(status: .healthy)
        health.record(result(1), sinceStart: .seconds(1), startPeriod: .seconds(10), retries: 2)
        #expect(health.status == .healthy)
        #expect(health.failingStreak == 1, "after a pass, the start period no longer shields failures")
    }

    @Test func failuresInTheStartPeriodDoNotCountUntilOnePasses() {
        var health = ContainerHealth()
        for second in [1, 3, 5, 7, 9] {
            health.record(result(1), sinceStart: .seconds(second), startPeriod: .seconds(10), retries: 2)
        }
        #expect(health.status == .starting)
        #expect(health.failingStreak == 0)
        health.record(result(1), sinceStart: .seconds(10), startPeriod: .seconds(10), retries: 2)
        #expect(health.failingStreak == 1, "a check that starts at the end of the period counts")
    }

    @Test func theLogKeepsTheLastFive() {
        var health = ContainerHealth()
        for code in Int32(0)..<7 {
            health.record(result(code), sinceStart: .seconds(60), startPeriod: .zero, retries: 3)
        }
        #expect(health.log.map(\.exitCode) == [2, 3, 4, 5, 6])
    }

    @Test func theScheduleIsTheStartIntervalWhileStartingInThePeriod() {
        // Start interval defaults to 5 s; the period is 10 s; the interval is 2 s.
        #expect(ContainerHealth.delayBeforeNextCheck(status: .starting, sinceStart: .zero, check: check) == .seconds(5))
        #expect(ContainerHealth.delayBeforeNextCheck(status: .starting, sinceStart: .seconds(7), check: check) == .seconds(3), "no later than the period's end")
        #expect(ContainerHealth.delayBeforeNextCheck(status: .healthy, sinceStart: .seconds(1), check: check) == .seconds(2))
        #expect(ContainerHealth.delayBeforeNextCheck(status: .starting, sinceStart: .seconds(10), check: check) == .seconds(2))
        let noPeriod = HealthCheckConfiguration(test: ["CMD", "true"])
        #expect(ContainerHealth.delayBeforeNextCheck(status: .starting, sinceStart: .zero, check: noPeriod) == .seconds(30), "the first check waits one interval")
    }

    @Test func outputIsKeptToFourKilobytes() {
        #expect(ContainerHealth.keptOutput(Data("ok\n".utf8), truncated: false) == "ok\n")
        let long = Data(repeating: UInt8(ascii: "x"), count: 5000)
        let kept = ContainerHealth.keptOutput(long, truncated: false)
        #expect(kept.hasSuffix("..."))
        #expect(kept.utf8.count == 4096 + 3)
    }

    @Test func healthTravelsInTheSnapshotAndOlderSnapshotsHaveNone() throws {
        let config = makeTestConfiguration()
        let snapshot = ContainerSnapshot(
            configuration: config, status: .running, networks: [], health: ContainerHealth(status: .healthy, failingStreak: 0, log: [result(0, output: "fine")]))
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: try JSONEncoder().encode(snapshot))
        #expect(decoded.health == snapshot.health)
        #expect(ManagedContainer(decoded).status.health?.status == .healthy)

        let older = try JSONDecoder().decode(
            ContainerSnapshot.self, from: try JSONEncoder().encode(ContainerSnapshot(configuration: config, status: .running, networks: [])))
        #expect(older.health == nil)
    }
}
