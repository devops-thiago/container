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
import Foundation
import Testing

@testable import ContainerAPIService

/// Whatever client creates the container, a bind of the host's Docker socket reaches the engine
/// as one of the engine's own socket.
struct DockerHostSocketCreateTests {
    @Test("the engine binds its own Docker socket for the host's, and leaves every other mount")
    func bindsTheEngineSocket() {
        var configuration = ContainerConfiguration(
            id: "app",
            image: .init(
                reference: "fixture:latest",
                descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        configuration.mounts = [
            .virtiofs(source: "/var/run/docker.sock", destination: "/var/run/docker.sock", options: []),
            .virtiofs(source: "/private/var/run/docker.sock", destination: "/var/run/docker-host.sock", options: ["ro"]),
            .virtiofs(source: "/Users/me/src", destination: "/workspaces", options: []),
            .volume(name: "data", format: "ext4", source: "/volumes/data/volume.img", destination: "/data", options: []),
        ]
        let engine = "/Users/me/Library/Group Containers/group.example/run/docker.sock"
        let bound = ContainersService.bindingEngineDockerSocket(configuration, enginePath: engine)
        #expect(bound.mounts.map(\.source) == [engine, engine, "/Users/me/src", "/volumes/data/volume.img"])
        #expect(bound.mounts.map(\.destination) == configuration.mounts.map(\.destination))
        #expect(bound.mounts.map(\.options) == configuration.mounts.map(\.options))
    }
}
