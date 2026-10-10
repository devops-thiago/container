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

import ContainerResource
import ContainerRuntimeClient
import Foundation
import Synchronization
import Testing

@testable import ContainerAPIService

/// What the helper answers, one wait at a time, and what the watch asked and applied.
private final class Helper: Sendable {
    private struct State {
        var answers: [Result<HealthUpdate, any Error>]
        var asked: [UInt64] = []
        var applied: [HealthUpdate] = []
    }

    private let state: Mutex<State>
    /// What `apply` answers: whether the run is still the container's.
    private let current: @Sendable (HealthUpdate) -> Bool

    init(_ answers: [Result<HealthUpdate, any Error>], current: @escaping @Sendable (HealthUpdate) -> Bool = { _ in true }) {
        self.state = Mutex(State(answers: answers))
        self.current = current
    }

    var asked: [UInt64] { state.withLock { $0.asked } }
    var applied: [HealthUpdate] { state.withLock { $0.applied } }

    func wait(_ after: UInt64) throws -> HealthUpdate {
        try state.withLock { state in
            state.asked.append(after)
            guard !state.answers.isEmpty else { throw CancellationError() }
            return try state.answers.removeFirst().get()
        }
    }

    func apply(_ update: HealthUpdate) -> Bool {
        state.withLock { $0.applied.append(update) }
        return current(update)
    }

    func follow() async {
        await HealthWatch.follow(wait: { try self.wait($0) }, apply: { self.apply($0) })
    }
}

private struct HelperWentAway: Error {}

private func update(_ status: HealthStatus, generation: UInt64, finished: Bool = false) -> HealthUpdate {
    HealthUpdate(health: ContainerHealth(status: status), generation: generation, finished: finished)
}

struct HealthWatchTests {
    @Test func eachWaitStartsWhereTheLastAnswerEnded() async {
        let helper = Helper([.success(update(.starting, generation: 1)), .success(update(.healthy, generation: 3)), .success(update(.unhealthy, generation: 4, finished: true))])
        await helper.follow()
        #expect(helper.asked == [0, 1, 3])
        #expect(helper.applied.map { $0.health?.status } == [.starting, .healthy, .unhealthy])
    }

    @Test func aHelperThatGoesAwayEndsTheWatch() async {
        let helper = Helper([.success(update(.healthy, generation: 1)), .failure(HelperWentAway())])
        await helper.follow()
        #expect(helper.asked == [0, 1])
        #expect(helper.applied.count == 1)
    }

    @Test func aRunThatIsNoLongerTheContainersEndsTheWatch() async {
        let helper = Helper([.success(update(.healthy, generation: 1)), .success(update(.healthy, generation: 2))], current: { _ in false })
        await helper.follow()
        #expect(helper.asked == [0])
    }

    @Test func anAnswerThatIsNotNewerDoesNotSpin() async {
        let helper = Helper([.success(update(.healthy, generation: 2)), .success(update(.healthy, generation: 2)), .success(update(.healthy, generation: 5))])
        await helper.follow()
        #expect(helper.asked == [0, 2])
    }

    @Test func aCancelledWatchStops() async {
        let helper = Helper([.success(update(.healthy, generation: 1)), .success(update(.healthy, generation: 2))])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await helper.follow()
        }
        await task.value
        #expect(helper.applied.isEmpty)
    }

    @Test func theLogRunsAcrossRunsAndAStoppedRunIsUnhealthy() {
        let earlier = (0..<4).map { HealthCheckResult(start: Date(timeIntervalSince1970: Double($0)), end: Date(timeIntervalSince1970: Double($0)), exitCode: 0, output: "run 1") }
        let now = (0..<3).map {
            HealthCheckResult(start: Date(timeIntervalSince1970: Double(10 + $0)), end: Date(timeIntervalSince1970: Double(10 + $0)), exitCode: 1, output: "run 2")
        }
        let merged = HealthWatch.merged(ContainerHealth(status: .starting, failingStreak: 3, log: now), earlierLog: earlier)
        #expect(merged.log.count == ContainerHealth.maximumLogEntries)
        #expect(merged.log.map(\.output) == ["run 1", "run 1", "run 2", "run 2", "run 2"])
        #expect(merged.failingStreak == 3)

        let restarted = HealthWatch.starting(after: ContainerHealth(status: .unhealthy, failingStreak: 3, log: now))
        #expect(restarted.status == .starting)
        #expect(restarted.failingStreak == 0)
        #expect(restarted.log == now)

        #expect(HealthWatch.ended(nil) == nil, "no check, no health")
        #expect(HealthWatch.ended(ContainerHealth(status: .healthy))?.status == .unhealthy)
    }

    @Test func anUpdateCountsOnlyForTheRunningRunItIsFor() {
        let image = ImageDescription(
            reference: "docker.io/library/nginx:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0),
            supplementalGroups: [], rlimits: [])
        let configuration = ContainerConfiguration(id: "web", image: image, process: process)
        let run = UUID()
        let healthy = update(.healthy, generation: 1)

        var snapshot = ContainerSnapshot(configuration: configuration, incarnation: "a", status: .running, networks: [], health: ContainerHealth())
        #expect(HealthWatch.apply(healthy, to: &snapshot, currentRun: run, run: run, incarnation: "a", earlierLog: []))
        #expect(snapshot.health?.status == .healthy)

        var later = snapshot
        later.health = ContainerHealth()
        #expect(!HealthWatch.apply(healthy, to: &later, currentRun: UUID(), run: run, incarnation: "a", earlierLog: []), "a later run")
        #expect(!HealthWatch.apply(healthy, to: &later, currentRun: run, run: run, incarnation: "b", earlierLog: []), "a container of the same name made again")
        later.status = .stopped
        #expect(!HealthWatch.apply(healthy, to: &later, currentRun: run, run: run, incarnation: "a", earlierLog: []), "a run that has ended")
        #expect(later.health?.status == .starting, "none of them changed it")

        var nothing = snapshot
        #expect(HealthWatch.apply(HealthUpdate(health: nil, generation: 0, finished: true), to: &nothing, currentRun: run, run: run, incarnation: "a", earlierLog: []))
        #expect(nothing.health == snapshot.health)
    }
}
