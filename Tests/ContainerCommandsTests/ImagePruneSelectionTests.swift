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

import Testing

@testable import ContainerCommands

/// What `image prune` picks. The init image the engine starts containers with is held by
/// digest, so it looks dangling and unused; a prune that removed it made the next start
/// download it again.
struct ImagePruneSelectionTests {
    private let initImage = "ghcr.io/devops-thiago/containerization/vminit@sha256:8a30a8862003aba95e4da67ebc1bf6c374b0f16b472ce06a630a96d266b9f5ce"
    private let previousInit = "ghcr.io/devops-thiago/containerization/vminit@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    private let dangling = "docker.io/library/moby-dangling@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    private let alpine = "docker.io/library/alpine:3.20"
    private let busybox = "docker.io/library/busybox:1.36"

    private func pruned(all: Bool, inUse: Set<String> = []) -> Set<String> {
        Application.ImagePrune.referencesToPrune(
            [initImage, previousInit, dangling, alpine, busybox], all: all, inUse: inUse, initImage: initImage)
    }

    @Test func pruneRemovesUntaggedImagesButNotTheConfiguredInitImage() {
        #expect(pruned(all: false) == [previousInit, dangling])
    }

    @Test func pruneAllRemovesUnusedImagesButNotTheConfiguredInitImage() {
        #expect(pruned(all: true, inUse: [alpine]) == [previousInit, dangling, busybox])
    }

    /// With another init image configured, the one that was is an image like any other.
    @Test func initImageNoLongerConfiguredIsPruned() {
        let references = Application.ImagePrune.referencesToPrune([initImage, alpine], all: false, inUse: [], initImage: previousInit)
        #expect(references == [initImage])
    }
}
