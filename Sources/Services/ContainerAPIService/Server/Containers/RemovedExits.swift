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

/// The exits of the last few containers removed when they stopped.
///
/// `container run --rm` starts the process and then waits on it. A process that ends at once
/// is removed on its exit before that wait arrives, and the wait found no container: the run
/// failed with "not found" though the process had exited 0. Kept bounded, newest last; a
/// container made again under the same name replaces its entry when it exits.
struct RemovedExits {
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
