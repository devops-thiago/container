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

import ContainerizationExtras
import Foundation
import Synchronization
import Testing

@testable import ContainerAPIService

/// The restore of saved networks at engine start runs with the listener up, so a network
/// can be created through it meanwhile. These hold the restore between reading the store
/// and reaching a network, and create that network in the gap.
struct NetworkRestoreTests {
    /// What is saved, what is running, and how often each network's helper was registered.
    private final class Helpers: Sendable {
        private let state = Mutex<(saved: [String: String], running: Set<String>, registered: [String])>(([:], [], []))
        init(saved: [String] = []) { state.withLock { for id in saved { $0.saved[id] = id } } }
        var registered: [String] { state.withLock { $0.registered } }
        func isRunning(_ id: String) -> Bool { state.withLock { $0.running.contains(id) } }
        func saved(_ id: String) -> String? { state.withLock { $0.saved[id] } }
        func save(_ id: String, as configuration: String? = nil) { state.withLock { $0.saved[id] = configuration ?? id } }
        func register(_ id: String) {
            state.withLock {
                $0.registered.append(id)
                $0.running.insert(id)
            }
        }
        /// What `NetworksService.delete` does: out of the running set and out of the store.
        func remove(_ id: String) {
            state.withLock {
                $0.running.remove(id)
                $0.saved[id] = nil
            }
        }
    }

    /// Holds the restore where a test asks, until the test lets it go.
    private final class Checkpoint: Sendable {
        private let reached: AsyncStream<Void>
        private let reach: AsyncStream<Void>.Continuation
        private let resumed: AsyncStream<Void>
        private let resume: AsyncStream<Void>.Continuation

        init() {
            (reached, reach) = AsyncStream.makeStream()
            (resumed, resume) = AsyncStream.makeStream()
        }

        func pause() async {
            reach.yield()
            for await _ in resumed { return }
        }

        func arrival() async {
            for await _ in reached { return }
        }

        func release() { resume.yield() }
    }

    /// What `NetworksService.create` does to the running set: under the lock, refuse a
    /// network that is running, otherwise register its helper.
    private func create(_ id: String, helpers: Helpers, lock: AsyncLock) async -> Bool {
        await lock.withLock { _ in
            guard !helpers.isRunning(id) else { return false }
            helpers.save(id)
            helpers.register(id)
            return true
        }
    }

    /// What `NetworksService.delete` does, under the same lock.
    private func delete(_ id: String, helpers: Helpers, lock: AsyncLock) async {
        await lock.withLock { _ in helpers.remove(id) }
    }

    /// The restore as the service runs it over `ids`, against `helpers`.
    private func restore(_ ids: [String], helpers: Helpers, lock: AsyncLock, beforeStart: @Sendable @escaping (String) async -> Void = { _ in }) async {
        await NetworksService.restore(
            ids, under: lock,
            saved: { id in helpers.saved(id) == nil ? nil : id },
            isRunning: { helpers.isRunning($0) },
            start: { id in
                await beforeStart(id)
                helpers.register(id)
            })
    }

    @Test("a network created while the restore is under way is not registered a second time")
    func createDuringRestore() async {
        let helpers = Helpers(saved: ["default", "made"])
        let lock = AsyncLock()
        let first = Checkpoint()
        // The store listing already holds "made": it was created and saved after the engine
        // came up and before the restore read the store.
        let restore = Task {
            await self.restore(["default", "made"], helpers: helpers, lock: lock) { id in
                if id == "default" { await first.pause() }
            }
        }
        await first.arrival()
        // The restore holds the lock on "default". The create waits for it.
        let created = Task { await create("made", helpers: helpers, lock: lock) }
        first.release()
        await restore.value
        _ = await created.value
        #expect(helpers.registered.filter { $0 == "made" }.count == 1)
        #expect(helpers.registered.filter { $0 == "default" }.count == 1)
    }

    @Test("a network running before its turn in the restore is left alone")
    func runningNetworkIsSkipped() async {
        let helpers = Helpers(saved: ["default"])
        let lock = AsyncLock()
        #expect(await create("made", helpers: helpers, lock: lock))
        await restore(["default", "made"], helpers: helpers, lock: lock)
        #expect(helpers.registered == ["made", "default"])
    }

    @Test("with nothing else going on, every saved network is started once, in order")
    func restoresEverySavedNetwork() async {
        let helpers = Helpers(saved: ["default", "backend", "frontend"])
        await restore(["default", "backend", "frontend"], helpers: helpers, lock: AsyncLock())
        #expect(helpers.registered == ["default", "backend", "frontend"])
    }

    @Test("a create of a network the restore has just started is refused, as it is once the engine is up")
    func createAfterRestoreStartedIt() async {
        let helpers = Helpers(saved: ["made"])
        let lock = AsyncLock()
        await restore(["made"], helpers: helpers, lock: lock)
        #expect(await create("made", helpers: helpers, lock: lock) == false)
        #expect(helpers.registered == ["made"])
    }

    @Test("a network deleted after the store was listed and before its turn stays deleted")
    func deletedBeforeItsTurn() async {
        let helpers = Helpers(saved: ["default"])
        let lock = AsyncLock()
        // "made" was created, so saved and running, when the store was listed.
        #expect(await create("made", helpers: helpers, lock: lock))
        let listed = ["default", "made"]
        // It is deleted while the restore is on "default": after the listing, and over
        // before the restore can take the lock for "made". The delete is made from inside
        // that turn, so the order does not depend on which task runs first.
        await restore(listed, helpers: helpers, lock: lock) { id in
            if id == "default" { helpers.remove("made") }
        }
        #expect(helpers.registered == ["made", "default"], "the deleted network was not started again")
        #expect(!helpers.isRunning("made") && helpers.saved("made") == nil)
    }

    @Test("a network deleted and saved again before its turn is started as the store holds it now")
    func replacedBeforeItsTurn() async {
        let helpers = Helpers(saved: ["default", "made"])
        let lock = AsyncLock()
        // What the restore handed to `start`, as it was handed over.
        let started = Mutex<[String]>([])
        await NetworksService.restore(
            ["default", "made"], under: lock,
            saved: { helpers.saved($0) },
            isRunning: { helpers.isRunning($0) },
            start: { configuration in
                started.withLock { $0.append(configuration) }
                // While the restore is on "default", "made" is deleted and saved again
                // with another configuration, and is not running.
                guard configuration == "default" else { return }
                helpers.remove("made")
                helpers.save("made", as: "made, as saved again")
            })
        #expect(started.withLock { $0 } == ["default", "made, as saved again"])
    }
}
