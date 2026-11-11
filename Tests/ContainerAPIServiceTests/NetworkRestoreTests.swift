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
    /// What is running and how often each network's helper was registered.
    private final class Helpers: Sendable {
        private let state = Mutex<(running: Set<String>, registered: [String])>(([], []))
        var registered: [String] { state.withLock { $0.registered } }
        func isRunning(_ id: String) -> Bool { state.withLock { $0.running.contains(id) } }
        func register(_ id: String) {
            state.withLock {
                $0.registered.append(id)
                $0.running.insert(id)
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
            helpers.register(id)
            return true
        }
    }

    @Test("a network created while the restore is under way is not registered a second time")
    func createDuringRestore() async {
        let helpers = Helpers()
        let lock = AsyncLock()
        let first = Checkpoint()
        // The store listing already holds "made": it was created and saved after the engine
        // came up and before the restore read the store.
        let restore = Task {
            await NetworksService.restore(
                ["default", "made"], under: lock,
                isRunning: { helpers.isRunning($0) },
                start: { id in
                    if id == "default" { await first.pause() }
                    helpers.register(id)
                })
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
        let helpers = Helpers()
        let lock = AsyncLock()
        #expect(await create("made", helpers: helpers, lock: lock))
        await NetworksService.restore(
            ["default", "made"], under: lock,
            isRunning: { helpers.isRunning($0) },
            start: { helpers.register($0) })
        #expect(helpers.registered == ["made", "default"])
    }

    @Test("with nothing else going on, every saved network is started once, in order")
    func restoresEverySavedNetwork() async {
        let helpers = Helpers()
        await NetworksService.restore(
            ["default", "backend", "frontend"], under: AsyncLock(),
            isRunning: { helpers.isRunning($0) },
            start: { helpers.register($0) })
        #expect(helpers.registered == ["default", "backend", "frontend"])
    }

    @Test("a create of a network the restore has just started is refused, as it is once the engine is up")
    func createAfterRestoreStartedIt() async {
        let helpers = Helpers()
        let lock = AsyncLock()
        await NetworksService.restore(["made"], under: lock, isRunning: { helpers.isRunning($0) }, start: { helpers.register($0) })
        #expect(await create("made", helpers: helpers, lock: lock) == false)
        #expect(helpers.registered == ["made"])
    }
}
