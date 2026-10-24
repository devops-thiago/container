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

@testable import ContainerAPIClient

struct InfrastructureImageMigrationTests {
    private let current = "ghcr.io/devops-thiago/containerization/vminit@sha256:1234"
    private let builder = "ghcr.io/apple/container-builder-shim/builder:0.1.0"

    @Test(arguments: [
        "ghcr.io/apple/containerization/vminit:0.45.0",
        "ghcr.io/apple/containerization/vminit:0.47.0",
        "ghcr.io/apple/containerization/vminit@sha256:5678",
        "ghcr.io/devops-thiago/containerization/vminit:sha-previous",
    ])
    func knownGuestRepositoriesStayHiddenAfterUpgrade(reference: String) {
        #expect(Utility.isInfraImage(name: reference, builderImage: builder, initImage: current))
    }

    @Test(arguments: [
        "example.com/team/vminit:latest",
        "ghcr.io/apple/containerization/vminit-extra:latest",
        "ghcr.io/apple/containerization/vminit/nested:latest",
        "registry.local:5000/user/app:latest",
    ])
    func unrelatedImagesRemainVisible(reference: String) {
        #expect(!Utility.isInfraImage(name: reference, builderImage: builder, initImage: current))
    }

    @Test
    func customGuestRepositoryStillFiltersAllVersions() {
        #expect(
            Utility.isInfraImage(
                name: "registry.local:5000/private/init:old", builderImage: builder,
                initImage: "registry.local:5000/private/init@sha256:1234"))
    }
}
