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
import Synchronization

/// Keeps process identity independent of the service label reused on a restart.
final class SpawnedInstances: Sendable {
    private struct Entry {
        let label: String
        let process: Process
    }

    private struct State {
        var entries: [ObjectIdentifier: Entry] = [:]
        var shuttingDown = false
    }

    private let state = Mutex(State())
    private let launchTransactionDidFinish: (@Sendable ([Process]) -> Void)?

    init(launchTransactionDidFinish: (@Sendable ([Process]) -> Void)? = nil) {
        self.launchTransactionDidFinish = launchTransactionDidFinish
    }

    /// Launch and registration share the shutdown lock. A fast exit callback waits for
    /// registration; a shutdown either includes this child or refuses its launch entirely.
    func start(
        _ process: Process, label: String, run: (Process) throws -> Void = { try $0.run() }
    ) throws -> [Process] {
        try state.withLock { state in
            // Observe the transaction's final registry while it still owns the lock. This
            // makes shutdown/registration ordering testable without racing thread timing.
            defer { launchTransactionDidFinish?(state.entries.values.map(\.process)) }
            guard !state.shuttingDown else {
                throw ContainerizationError(.invalidState, message: "engine is shutting down")
            }
            try run(process)
            let previous = state.entries.values.filter { $0.label == label }.map(\.process)
            state.entries[ObjectIdentifier(process)] = Entry(label: label, process: process)
            return previous
        }
    }

    func didExit(_ process: Process) {
        state.withLock { _ = $0.entries.removeValue(forKey: ObjectIdentifier(process)) }
    }

    func processes(label: String) -> [Process] {
        state.withLock { $0.entries.values.filter { $0.label == label }.map(\.process) }
    }

    var labels: [String] {
        state.withLock { Array(Set($0.entries.values.map(\.label))) }
    }

    func beginShutdown() -> [Process] {
        state.withLock {
            $0.shuttingDown = true
            return $0.entries.values.map(\.process)
        }
    }
}
