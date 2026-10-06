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
import Testing

@testable import ContainerPlugin

struct PluginLoaderLifecycleTests {
    @Test func defaultOperationsLaunchTerminateAndReapARealChild() async throws {
        let tracking = SpawnedInstances()
        try PluginLoader.spawnInstance(
            label: "lifecycle-test", instanceId: "lifecycle-test", argv: ["/bin/sleep", "60"],
            env: [:], log: nil, tracking: tracking)
        let child = try #require(tracking.processes(label: "lifecycle-test").first)
        defer { if child.isRunning { child.terminate() } }
        #expect(child.isRunning)
        PluginLoader.terminateInstance(label: "lifecycle-test", log: nil, tracking: tracking)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !tracking.processes(label: "lifecycle-test").isEmpty {
            try #require(ContinuousClock.now < deadline, "the real child's exit callback must remove its registration")
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!child.isRunning)
    }

    @Test func replacementsRetireEveryRunningPredecessor() throws {
        let tracking = SpawnedInstances()
        var launched: [Process] = []
        var terminated: [ObjectIdentifier] = []
        var exited: Set<ObjectIdentifier> = []
        let operations = PluginLoader.ProcessOperations(
            run: { launched.append($0) },
            isRunning: { !exited.contains(ObjectIdentifier($0)) },
            terminate: { terminated.append(ObjectIdentifier($0)) })
        func spawn(_ label: String) throws {
            try PluginLoader.spawnInstance(
                label: label, instanceId: label, argv: ["/fixture/runtime", "--uuid", label],
                env: ["CONTAINER_TEST": "1"], log: nil, tracking: tracking, operations: operations)
        }
        try spawn("other")
        try spawn("web")
        let first = launched[1]
        #expect(terminated.isEmpty)
        try spawn("web")
        let second = launched[2]
        #expect(terminated == [ObjectIdentifier(first)])
        terminated.removeAll()
        try spawn("web")
        #expect(Set(terminated) == Set([first, second].map(ObjectIdentifier.init)))
        #expect(tracking.processes(label: "web").count == 3, "asking for exit must not forget a still-running generation")
        exited.insert(ObjectIdentifier(first))
        terminated.removeAll()
        try spawn("web")
        #expect(Set(terminated) == Set([second, launched[3]].map(ObjectIdentifier.init)))
        #expect(launched.last?.arguments == ["--uuid", "web"])
        #expect(launched.last?.environment == ["CONTAINER_TEST": "1"])
    }

    @Test func terminatingAnInstanceVisitsAllItsRunningGenerations() throws {
        let tracking = SpawnedInstances()
        let generations = (0..<4).map { _ in Process() }
        for process in generations { _ = try tracking.start(process, label: "web", run: { _ in }) }
        _ = try tracking.start(Process(), label: "other", run: { _ in })
        var terminated: [ObjectIdentifier] = []
        let operations = PluginLoader.ProcessOperations(
            isRunning: { $0 !== generations[1] },
            terminate: { terminated.append(ObjectIdentifier($0)) })
        PluginLoader.terminateInstance(label: "web", log: nil, tracking: tracking, operations: operations)
        #expect(Set(terminated) == Set([generations[0], generations[2], generations[3]].map(ObjectIdentifier.init)))
        #expect(terminated.count == 3)
        #expect(tracking.processes(label: "web").count == 4)
        PluginLoader.terminateInstance(label: "absent", log: nil, tracking: tracking, operations: operations)
        #expect(terminated.count == 3)
    }

    @Test func aFailedSpawnDoesNotRetireTheCurrentHelper() throws {
        enum Failure: Error { case launch }
        let tracking = SpawnedInstances()
        let current = Process()
        _ = try tracking.start(current, label: "web", run: { _ in })
        var terminated = false
        let operations = PluginLoader.ProcessOperations(
            run: { _ in throw Failure.launch }, isRunning: { _ in true }, terminate: { _ in terminated = true })
        #expect(throws: Failure.launch) {
            try PluginLoader.spawnInstance(
                label: "web", instanceId: "web", argv: ["/fixture/runtime"], env: [:], log: nil,
                tracking: tracking, operations: operations)
        }
        #expect(!terminated)
        #expect(tracking.processes(label: "web").first === current)
    }

    /// A helper that never announces used to be left running, and its registration returned
    /// as if it had; the failure showed later, at the first call, as a connection error.
    @Test func aHelperThatNeverAnnouncesIsTerminatedAndTheRegistrationFails() throws {
        let tracking = SpawnedInstances()
        let child = Process()
        _ = try tracking.start(child, label: "web", run: { _ in })
        var terminated: [ObjectIdentifier] = []
        let operations = PluginLoader.ProcessOperations(isRunning: { _ in true }, terminate: { terminated.append(ObjectIdentifier($0)) })
        var asked: [String] = []

        #expect {
            try PluginLoader.awaitAnnouncement(
                label: "web", services: ["runtime.web", "logs.web"], timeout: 0.01, log: nil, tracking: tracking,
                operations: operations,
                waitForAttach: { service, _ in
                    asked.append(service)
                    return service == "runtime.web"
                })
        } throws: { error in
            let failure = error as? ContainerizationError
            return failure?.code == .timeout && failure?.message.contains("logs.web") == true && failure?.message.contains("web") == true
        }
        #expect(asked == ["runtime.web", "logs.web"], "the wait stops at the first service that never came")
        #expect(terminated == [ObjectIdentifier(child)])

        terminated.removeAll()
        try PluginLoader.awaitAnnouncement(
            label: "web", services: ["runtime.web"], timeout: 0.01, log: nil, tracking: tracking,
            operations: operations, waitForAttach: { _, _ in true })
        #expect(terminated.isEmpty, "one that announced is left alone")
    }

    @Test func aSiblingInstallWhoseNameStartsTheSameIsNotMatched() {
        let root = "/Applications/SiliconShip.app/Contents"
        let own = "/Applications/SiliconShip.app/Contents/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"
        #expect(PluginLoader.ownedHelperPath(own, under: root) == own)
        #expect(PluginLoader.ownedHelperPath(own, under: root + "/") == own)
        let sibling = "/Applications/SiliconShip.app/Contents-old/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"
        #expect(PluginLoader.ownedHelperPath(sibling, under: root) == nil, "the string starts the same; the path does not lie under the root")
        #expect(PluginLoader.ownedHelperPath("/Applications/SiliconShip.app/Contents/MacOS/container", under: root) == nil, "not a plugin helper")
        #expect(PluginLoader.ownedHelperPath("/Applications/Other.app/Contents/libexec/container/plugins/x/bin/x", under: root) == nil)
    }

    /// The buffer used to hold 4,096 ids whatever the count, and an orphan past that was never seen.
    @Test func anOrphanBeyondFourThousandEntriesIsFound() {
        let total = 5_000
        let orphan: pid_t = 70_000
        var sizes: [Int] = []
        var signalled: [pid_t] = []
        let victims = PluginLoader.reapOrphanedInstances(
            installRoot: URL(fileURLWithPath: "/fixture"),
            listAllPIDs: { pointer, bytes in
                guard let pointer else {
                    #expect(bytes == 0, "the count is asked for with no buffer")
                    return Int32(total)
                }
                sizes.append(Int(bytes) / MemoryLayout<pid_t>.size)
                let buffer = pointer.assumingMemoryBound(to: pid_t.self)
                for index in 0..<total { buffer[index] = index == 4_500 ? orphan : pid_t(1_000 + index) }
                return Int32(total)
            },
            helperPath: { pid, _ in pid == orphan ? "/fixture/libexec/container/plugins/runtime" : nil },
            signal: { pid, _ in signalled.append(pid) })
        #expect(sizes == [total + 256], "sized from the count, with room for processes that start meanwhile")
        #expect(victims == [orphan])
        #expect(signalled == [orphan])
    }

    @Test func aBufferThatFillsIsGrownAndAskedAgain() {
        var sizes: [Int] = []
        let (pids, count) = PluginLoader.processInventory { pointer, bytes in
            guard pointer != nil else { return 100 }
            let slots = Int(bytes) / MemoryLayout<pid_t>.size
            sizes.append(slots)
            // More processes than the first buffer holds: the answer fills it to the end.
            return Int32(slots < 500 ? slots : 500)
        }
        #expect(sizes == [356, 712])
        #expect(count == 500)
        #expect(pids.count == 712)
    }

    @Test func orphanScanTreatsTheInventoryResultAsACount() {
        let last: pid_t = getpid() + 100
        let slots: [pid_t] = [0, -1, getpid(), last - 4, last - 3, last - 2, last - 1, last, last + 1]
        var inspected: [pid_t] = []
        var signalled: [pid_t] = []
        let victims = PluginLoader.reapOrphanedInstances(
            installRoot: URL(fileURLWithPath: "/fixture"),
            listAllPIDs: { pointer, bytes in
                guard let pointer else { return 8 }
                #expect(bytes == (8 + 256) * MemoryLayout<pid_t>.size)
                let buffer = pointer.assumingMemoryBound(to: pid_t.self)
                for (index, pid) in slots.enumerated() { buffer[index] = pid }
                return 8
            },
            helperPath: { pid, root in
                inspected.append(pid)
                #expect(root == "/fixture")
                return pid == last ? "/fixture/libexec/container/plugins/runtime" : nil
            },
            signal: { pid, signal in
                #expect(signal == SIGTERM)
                signalled.append(pid)
            })
        #expect(inspected == Array(slots[3..<8]), "all eight returned slots are scanned, and the ninth is ignored")
        #expect(victims == [last])
        #expect(signalled == [last])
    }

    @Test(arguments: [Int32(-1), 0])
    func anEmptyOrFailedInventorySignalsNothing(count: Int32) {
        let victims = PluginLoader.reapOrphanedInstances(
            installRoot: URL(fileURLWithPath: "/fixture"),
            listAllPIDs: { _, _ in count },
            helperPath: { _, _ in
                Issue.record("unexpected path lookup")
                return nil
            },
            signal: { _, _ in Issue.record("unexpected signal") })
        #expect(victims.isEmpty)
    }
}
