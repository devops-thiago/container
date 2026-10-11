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

/// What a runtime helper answers a wait for health with: the container's health as its
/// checks have left it in this run, and where that is in the run's history.
public struct HealthUpdate: Sendable, Codable, Equatable {
    /// Nil when the run has no check to run.
    public var health: ContainerHealth?
    /// How many checks have been recorded in this run. A wait past this number returns at
    /// the next one.
    public var generation: UInt64
    /// No more checks will run in this run: it has stopped, or it has none.
    public var finished: Bool

    public init(health: ContainerHealth?, generation: UInt64, finished: Bool) {
        self.health = health
        self.generation = generation
        self.finished = finished
    }
}
