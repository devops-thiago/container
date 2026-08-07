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

public enum MachineKeys: String {
    /// Container machine ID.
    case id
    /// Container machine configuration.
    case machineConfig
    /// Container machine resources.
    case machineResources
    /// List of container machine snapshots.
    case machines
    /// Single container machine snapshot.
    case snapshot
    /// Boot-time configuration.
    case bootConfig
    /// File handles to logs
    case logs
    /// Special-case environment variables recomputed on container machine start
    case dynamicEnv
    /// Bookmark data authorizing the home directory a machine mounts.
    ///
    /// The machine service cannot mint this for itself. A bookmark lends exactly the reach its
    /// maker holds, so one made here for a folder this process cannot open would resolve to the
    /// right directory and lend nothing (`docs/sandbox-spikes.md`, S4r6). It has to come from
    /// the embedder, which is where the user answered the panel.
    case hostDirectoryBookmarks
}
