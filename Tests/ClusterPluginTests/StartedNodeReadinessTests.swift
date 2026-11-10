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

struct StartedNodeReadinessTests {
    private typealias Report = ClusterHelper.NodeReadyReport
    private let log = Logger(label: "started-node-readiness-tests")

    /// The guest's clock, deliberately nowhere near this Mac's: only a node's own times
    /// are compared.
    private static let boot = Date(timeIntervalSince1970: 4_000_000_000)
    private static let beforeStop = boot.addingTimeInterval(-90)
    private static let afterBoot = boot.addingTimeInterval(12)
    private static let started = ["dev", "dev-worker-1"].map { ClusterHelper.StartedNode(name: $0, bootedAt: boot) }

    private final class Fixture: Sendable {
        let instant = Mutex(ContinuousClock.now)
        let listings = Mutex(0)
        let podProbes = Mutex(0)
        func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
    }

    private func wait(
        _ fixture: Fixture, started: [ClusterHelper.StartedNode] = StartedNodeReadinessTests.started,
        nodes: @escaping @Sendable (Int) -> [ClusterHelper.NodeReadyReport]?
    ) async throws {
        try await ClusterHelper.waitForReady(
            containerId: "dev", log: log, started: started, now: { fixture.now() }, sleep: { fixture.advance($0) },
            nodes: { _ in
                nodes(
                    fixture.listings.withLock { count in
                        count += 1
                        return count
                    })
            }
        ) { arguments, _ in
            #expect(arguments.contains("deployment/coredns"))
            fixture.podProbes.withLock { $0 += 1 }
            return 0
        }
    }

    private func timeout(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            Issue.record("readiness succeeded")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            return error.message
        } catch { Issue.record("unexpected error: \(error)") }
        return ""
    }

    @Test func readyConditionsFromBeforeTheStopNeverSucceed() async {
        let fixture = Fixture()
        let start = fixture.now()
        let message = await timeout {
            try await wait(fixture) { _ in
                [
                    Report(name: "dev", ready: true, heartbeat: Self.beforeStop),
                    Report(name: "dev-worker-1", ready: true, heartbeat: Self.beforeStop),
                ]
            }
        }
        #expect(message.contains("dev: no report since it booted, dev-worker-1: no report since it booted"))
        #expect(fixture.listings.withLock { $0 } > 1)
        #expect(fixture.podProbes.withLock { $0 } == 0)
        #expect(start.duration(to: fixture.now()) == .seconds(300))
    }

    @Test func readyConditionsWrittenSinceEachBootSucceed() async throws {
        let fixture = Fixture()
        try await wait(fixture) { listing in
            // The control plane reports first; the worker's condition is still the old one.
            [
                Report(name: "dev", ready: true, heartbeat: Self.afterBoot),
                Report(name: "dev-worker-1", ready: true, heartbeat: listing < 3 ? Self.beforeStop : Self.afterBoot),
            ]
        }
        #expect(fixture.listings.withLock { $0 } == 3)
        #expect(fixture.podProbes.withLock { $0 } == 1)
    }

    @Test func eachNodeIsHeldToItsOwnBoot() async throws {
        let fixture = Fixture()
        let later = Self.boot.addingTimeInterval(3600)
        let started = [
            ClusterHelper.StartedNode(name: "dev", bootedAt: Self.boot),
            ClusterHelper.StartedNode(name: "dev-worker-1", bootedAt: later),
        ]
        let message = await timeout {
            try await wait(fixture, started: started) { _ in
                [
                    Report(name: "dev", ready: true, heartbeat: Self.afterBoot),
                    Report(name: "dev-worker-1", ready: true, heartbeat: Self.afterBoot),
                ]
            }
        }
        #expect(message.contains("(dev-worker-1: no report since it booted)"))
    }

    @Test func aHeartbeatInTheSecondOfTheBootCounts() {
        let reports = [Report(name: "dev", ready: true, heartbeat: Self.boot)]
        #expect(ClusterHelper.unreadyNodes(reports: reports, started: [.init(name: "dev", bootedAt: Self.boot)]).isEmpty)
    }

    @Test func timeoutNamesEveryNodeThatWasNotReady() async {
        let fixture = Fixture()
        let started = Self.started + [.init(name: "dev-worker-2", bootedAt: Self.boot), .init(name: "dev-worker-3", bootedAt: Self.boot)]
        let message = await timeout {
            try await wait(fixture, started: started) { _ in
                [
                    Report(name: "dev", ready: true, heartbeat: Self.afterBoot),
                    Report(name: "dev-worker-1", ready: false, heartbeat: Self.afterBoot),
                    Report(name: "dev-worker-2", ready: true, heartbeat: nil),
                    Report(name: "stray", ready: false, heartbeat: nil),
                ]
            }
        }
        #expect(
            message
                == "cluster dev: the nodes did not all report Ready within 5m "
                + "(dev-worker-1: not Ready, dev-worker-2: no report since it booted, dev-worker-3: not registered, stray: not Ready); "
                + "inspect with 'container exec dev kubectl get nodes -o wide'")
        #expect(!message.contains("control-plane"))
    }

    @Test func timeoutWithNoAnswerNamesTheNodesThatWereStarted() async {
        let fixture = Fixture()
        let message = await timeout { try await wait(fixture) { _ in nil } }
        #expect(message.contains("did not all report Ready within 5m (dev, dev-worker-1);"))
    }

    @Test func theLastAnswerIsKeptWhenALaterListingFails() async {
        let fixture = Fixture()
        let message = await timeout {
            try await wait(fixture) { listing in
                listing > 1
                    ? nil
                    : [
                        Report(name: "dev", ready: true, heartbeat: Self.afterBoot),
                        Report(name: "dev-worker-1", ready: false, heartbeat: nil),
                    ]
            }
        }
        #expect(message.contains("(dev-worker-1: not Ready);"))
    }

    @Test func createNeedsOnlyReadyAndAtLeastOneNode() async throws {
        let fixture = Fixture()
        try await wait(fixture, started: []) { listing in
            switch listing {
            case 1: []
            case 2: [Report(name: "dev", ready: true, heartbeat: nil), Report(name: "dev-worker-1", ready: false, heartbeat: nil)]
            default: [Report(name: "dev", ready: true, heartbeat: Self.beforeStop), Report(name: "dev-worker-1", ready: true, heartbeat: nil)]
            }
        }
        #expect(fixture.listings.withLock { $0 } == 3)
        #expect(fixture.podProbes.withLock { $0 } == 1)
    }

    @Test func createTimeoutWithNoNodesSaysSo() async {
        let fixture = Fixture()
        let message = await timeout { try await wait(fixture, started: []) { _ in [] } }
        #expect(message.contains("the nodes did not all report Ready within 5m; inspect"))
    }

    @Test func nodeListingIsParsedPerNode() {
        let output = "dev\tTrue\t2026-11-10T12:00:05Z\ndev-worker-1\tFalse\t2026-11-10T11:59:00Z\ndev-worker-2\tUnknown\t\ndev-worker-3\t\t\n"
        #expect(
            ClusterHelper.parseNodeReadyReports(output) == [
                Report(name: "dev", ready: true, heartbeat: Date(timeIntervalSince1970: 1_794_312_005)),
                Report(name: "dev-worker-1", ready: false, heartbeat: Date(timeIntervalSince1970: 1_794_311_940)),
                Report(name: "dev-worker-2", ready: false, heartbeat: nil),
                Report(name: "dev-worker-3", ready: false, heartbeat: nil),
            ])
        #expect(ClusterHelper.parseNodeReadyReports("").isEmpty)
        #expect(ClusterHelper.parseNodeReadyReports("dev\tTrue\t<nil>\n") == [Report(name: "dev", ready: true, heartbeat: nil)])
    }

    @Test func nodeListingAsksForTheReadyConditionOnly() {
        #expect(ClusterHelper.nodeReadyTemplate.contains(#"?(@.type=="Ready")].lastHeartbeatTime"#))
        #expect(!ClusterHelper.nodeReadyTemplate.contains("{range .status"))
    }

    @Test func bootTimeIsReadAsEpochSeconds() {
        #expect(ClusterHelper.parseBootTime("1794312000\n") == Date(timeIntervalSince1970: 1_794_312_000))
        #expect(ClusterHelper.parseBootTime("") == nil)
        #expect(ClusterHelper.parseBootTime("0\n") == nil)
        #expect(ClusterHelper.parseBootTime("btime 12\n") == nil)
    }
}
