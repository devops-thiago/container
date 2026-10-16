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

import ContainerImagesServiceClient
import ContainerizationError
import Foundation
import Testing

@testable import ContainerBuild
@testable import DockerAPIService

/// What the Docker API's `POST /build` shares with `container build`: the Dockerfile limit and
/// its words, and how a build's base image pulls find the client's credentials.
struct DockerBuildSharedRulesTests {
    @Test("the Docker API refuses the Dockerfiles container build refuses, in the same words")
    func dockerfileLimit() throws {
        #expect(DockerBuildContext.maxDockerfileBytes == Builder.maxBuildFileSize)
        for size in [Builder.maxBuildFileSize, Builder.maxBuildFileSize + 1, 3 << 20] {
            do {
                try Builder.checkBuildFileSize(Data(count: size))
                Issue.record("\(size) bytes passed")
            } catch let error as ContainerizationError {
                #expect(error.message == DockerBuildContext.tooLarge(size))
            }
            #expect(throws: DockerAPIError.badRequest(DockerBuildContext.tooLarge(size))) { try DockerBuildContext.checkSize(size) }
        }
        // Control: one byte under passes both.
        try Builder.checkBuildFileSize(Data(count: Builder.maxBuildFileSize - 1))
        try DockerBuildContext.checkSize(Builder.maxBuildFileSize - 1)
    }

    @Test("a base image pull takes the credential for its own registry, and only that one")
    func pullCredentials() {
        let hub = RegistryCredential(username: "hub", password: "p1")
        let local = RegistryCredential(username: "local", password: "p2")
        let credentials = ["docker.io": hub, "localhost:5999": local]
        #expect(BuildImageResolver.credential(for: "docker.io/library/alpine:3.22", in: credentials) == hub)
        #expect(BuildImageResolver.credential(for: "localhost:5999/team/base:1", in: credentials) == local)
        // Control: another registry, or none given, pulls with the engine's own logins.
        #expect(BuildImageResolver.credential(for: "ghcr.io/org/app:1", in: credentials) == nil)
        #expect(BuildImageResolver.credential(for: "docker.io/library/alpine:3.22", in: [:]) == nil)
        // The keys the Docker API makes are the ones a pull looks up.
        let header = Data(#"{"https://index.docker.io/v1/":{"username":"hub","password":"p1"}}"#.utf8).base64EncodedString()
        let keys = DockerRegistryAuth.credentials(configHeader: header).keys
        #expect(keys.allSatisfy { BuildImageResolver.credential(for: "\($0)/library/alpine:3.22", in: [$0: hub]) == hub })
        #expect(Array(keys) == ["docker.io"])
    }
}
