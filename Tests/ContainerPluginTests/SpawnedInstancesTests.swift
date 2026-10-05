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
import Synchronization
import Testing

@testable import ContainerPlugin

struct SpawnedInstancesTests {
    @Test func lateExitDoesNotForgetTheReplacement() throws {
        let instances = SpawnedInstances()
        let old = Process()
        let replacement = Process()
        _ = try instances.start(old, label: "web", run: { _ in })
        let predecessors = try instances.start(replacement, label: "web", run: { _ in })
        #expect(predecessors.count == 1 && predecessors.first === old)
        #expect(instances.processes(label: "web").count == 2)
        instances.didExit(old)
        #expect(instances.processes(label: "web").first === replacement)
        #expect(instances.beginShutdown().first === replacement)
    }

    @Test func shutdownRetainsEveryGenerationUntilItsExit() throws {
        let instances = SpawnedInstances()
        let generations = (0..<4).map { _ in Process() }
        for process in generations {
            _ = try instances.start(process, label: "web", run: { _ in })
        }
        #expect(Set(instances.beginShutdown().map(ObjectIdentifier.init)) == Set(generations.map(ObjectIdentifier.init)))
        for process in generations { instances.didExit(process) }
        #expect(instances.labels.isEmpty)
    }

    @Test func failedLaunchDoesNotReplaceExistingTracking() throws {
        enum Failure: Error { case launch }
        let instances = SpawnedInstances()
        let old = Process()
        _ = try instances.start(old, label: "web", run: { _ in })
        #expect(throws: Failure.self) {
            try instances.start(Process(), label: "web", run: { _ in throw Failure.launch })
        }
        #expect(instances.processes(label: "web").first === old)
    }

    @Test func shutdownRefusesNewLaunches() throws {
        let instances = SpawnedInstances()
        #expect(instances.beginShutdown().isEmpty)
        var launched = false
        #expect(throws: (any Error).self) {
            try instances.start(Process(), label: "web", run: { _ in launched = true })
        }
        #expect(!launched)
        #expect(instances.labels.isEmpty)
    }

    @Test func shutdownRacingAnAdmittedLaunchIncludesIt() async throws {
        let process = Process()
        let registeredAtUnlock = Mutex<[ObjectIdentifier]>([])
        let instances = SpawnedInstances { processes in
            registeredAtUnlock.withLock { $0 = processes.map(ObjectIdentifier.init) }
        }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let launchDone = DispatchSemaphore(value: 0)
        let shutdownDone = DispatchSemaphore(value: 0)
        let shutdownStarted = DispatchSemaphore(value: 0)
        let swept = Mutex<[Process]?>(nil)
        Thread.detachNewThread {
            defer { launchDone.signal() }
            do {
                _ = try instances.start(process, label: "web") { _ in
                    entered.signal()
                    #expect(release.wait(timeout: .now() + 5) == .success)
                }
            } catch { Issue.record(error) }
        }
        defer { release.signal() }
        try await waitFor(entered)
        Thread.detachNewThread {
            shutdownStarted.signal()
            let result = instances.beginShutdown()
            swept.withLock { $0 = result }
            shutdownDone.signal()
        }
        try await waitFor(shutdownStarted)
        #expect(swept.withLock { $0 == nil })
        release.signal()
        try await waitFor(launchDone)
        try await waitFor(shutdownDone)
        #expect(swept.withLock { $0?.first === process })
        #expect(
            registeredAtUnlock.withLock { $0 } == [ObjectIdentifier(process)],
            "registration must be complete before the launch transaction releases its lock")
    }

    @Test func immediateExitCannotLeaveARegisteredDeadProcess() async throws {
        let process = Process()
        let registeredAtUnlock = Mutex<[ObjectIdentifier]>([])
        let instances = SpawnedInstances { processes in
            registeredAtUnlock.withLock { $0 = processes.map(ObjectIdentifier.init) }
        }
        let exited = DispatchSemaphore(value: 0)
        let exitAttempted = DispatchSemaphore(value: 0)
        // Deliver the exit callback during run, before registration. It must wait for the
        // launch transaction and then remove the entry, even for an already-exited child.
        _ = try instances.start(process, label: "fast") { _ in
            Thread.detachNewThread {
                exitAttempted.signal()
                instances.didExit(process)
                exited.signal()
            }
            #expect(exitAttempted.wait(timeout: .now() + 5) == .success)
        }
        try await waitFor(exited)
        #expect(registeredAtUnlock.withLock { $0 } == [ObjectIdentifier(process)])
        #expect(instances.labels.isEmpty)
    }

    @Test func enumerationUsesEveryReturnedSlotAndChecksOwnership() {
        let pids: [pid_t] = [0, -1, 7, 8, 9, 10, 11, 12]
        let seen = Mutex<[pid_t]>([])
        let victims = PluginLoader.orphanCandidates(pids: pids, count: 8, selfPID: 7) { pid in
            seen.withLock { $0.append(pid) }
            return pid == 12 ? "/our/libexec/container/plugins/runtime" : nil
        }
        #expect(victims.map(\.0) == [12])
        #expect(seen.withLock { $0 } == [8, 9, 10, 11, 12])
        #expect(PluginLoader.orphanCandidates(pids: pids, count: -1, selfPID: 7, helperPath: { _ in "owned" }).isEmpty)
        #expect(PluginLoader.orphanCandidates(pids: pids, count: 100, selfPID: 7, helperPath: { _ in "owned" }).count == 5)
        #expect(PluginLoader.orphanCandidates(pids: pids, count: 4, selfPID: 7, helperPath: { _ in "owned" }).map(\.0) == [8])
    }

    private func signalled(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now()) == .success
    }

    private func waitFor(_ signal: DispatchSemaphore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !signalled(signal) {
            try #require(ContinuousClock.now < deadline, "worker did not finish within its bounded lifetime")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
