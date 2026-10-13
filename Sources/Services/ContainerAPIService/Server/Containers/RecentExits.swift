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

import Containerization

/// The last exit of each of the most recently stopped containers.
///
/// `container run` starts the process and then waits on it. A process that ends at once has
/// no runtime left when that wait arrives ("container is stopped"), or with `--rm` no
/// container ("not found"), and the run failed though the process had exited 0.
///
/// An exit belongs to one run of one container: it is kept with the container's
/// incarnation, a new container or a new run of the same one drops it, and it is answered
/// only for a short while, which is all a late wait needs. A container that reuses a
/// removed one's name never gets the removed one's exit. Bounded, newest last.
struct RecentExits {
    struct Entry {
        let id: String
        let incarnation: String
        let status: ExitStatus
        let recorded: ContinuousClock.Instant
    }

    /// What `wait` knows about the container it was asked about.
    struct Current {
        let incarnation: String
        let isStopped: Bool
    }

    private(set) var entries: [Entry] = []
    let capacity: Int
    let lifetime: Duration

    init(capacity: Int = 64, lifetime: Duration = .seconds(60)) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    /// The run of `id` with `incarnation` ended with `status`.
    mutating func record(_ status: ExitStatus, for id: String, incarnation: String, at now: ContinuousClock.Instant) {
        forget(id)
        entries.append(Entry(id: id, incarnation: incarnation, status: status, recorded: now))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// A container named `id` was created, or a new run of it started: no earlier exit is its.
    mutating func forget(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// The exit a wait on the init process of `id` gets without a runtime to ask: the last
    /// run's, while it is fresh, when the container is stopped and is the one that exited, or
    /// has been removed since. A running container, or another incarnation, gets nil and is
    /// asked as usual.
    func lateExit(for id: String, current: Current?, at now: ContinuousClock.Instant) -> ExitStatus? {
        guard let entry = entries.last(where: { $0.id == id }), now - entry.recorded <= lifetime else {
            return nil
        }
        guard let current else { return entry.status }
        guard current.isStopped, current.incarnation == entry.incarnation else { return nil }
        return entry.status
    }
}
