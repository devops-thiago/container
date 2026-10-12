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
/// container ("not found"), and the run failed though the process had exited 0. Kept
/// bounded, newest last; a container's next exit replaces its entry.
struct RecentExits {
    private(set) var entries: [(id: String, status: ExitStatus)] = []
    let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = capacity
    }

    mutating func record(_ status: ExitStatus, for id: String) {
        entries.removeAll { $0.id == id }
        entries.append((id, status))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func status(for id: String) -> ExitStatus? {
        entries.last { $0.id == id }?.status
    }
}
