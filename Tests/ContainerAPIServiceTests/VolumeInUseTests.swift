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

private func container(_ id: String, status: RuntimeStatus = .running, volumes: [String] = [], binds: [String] = []) -> ContainerSnapshot {
    var configuration = ContainerConfiguration(
        id: id,
        image: .init(
            reference: "fixture:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
        process: .init(executable: "/bin/true", arguments: [], environment: []))
    configuration.mounts =
        volumes.map { Filesystem.volume(name: $0, format: "ext4", source: "/volumes/\($0)/volume.img", destination: "/data", options: []) }
        + binds.map { Filesystem.virtiofs(source: $0, destination: "/host", options: []) }
    return ContainerSnapshot(configuration: configuration, status: status, networks: [])
}

/// A volume is a disk image, and one running container has it attached at a time.
struct VolumeInUseTests {
    @Test("a volume another running container mounts is reported with that container")
    func heldByARunningContainer() {
        let fleet = [container("db", volumes: ["data"]), container("cache", volumes: ["cache-data"])]
        let held = ContainersService.volumeInUse(by: fleet, neededBy: container("backup", volumes: ["logs", "data"]).configuration)
        #expect(held?.volume == "data")
        #expect(held?.container == "db")
    }

    @Test("a stopped container holds nothing, and one that is stopping still does")
    func onlyWhatRuns() {
        let needed = container("backup", volumes: ["data"]).configuration
        #expect(ContainersService.volumeInUse(by: [container("db", status: .stopped, volumes: ["data"])], neededBy: needed) == nil)
        #expect(ContainersService.volumeInUse(by: [container("db", status: .stopping, volumes: ["data"])], neededBy: needed)?.container == "db")
    }

    @Test("a container does not hold a volume against itself, and other mounts are not volumes")
    func notItselfAndNotFolders() {
        let fleet = [container("db", volumes: ["data"]), container("web", binds: ["/Users/someone/data"])]
        #expect(ContainersService.volumeInUse(by: fleet, neededBy: container("db", volumes: ["data"]).configuration) == nil)
        #expect(ContainersService.volumeInUse(by: fleet, neededBy: container("other", binds: ["/Users/someone/data"]).configuration) == nil)
        #expect(ContainersService.volumeInUse(by: fleet, neededBy: container("plain").configuration) == nil)
    }

    @Test("with two holders the answer does not depend on the order they are listed in")
    func stable() {
        let needed = container("backup", volumes: ["data"]).configuration
        let fleet = [container("zeta", volumes: ["data"]), container("alpha", volumes: ["data"])]
        #expect(ContainersService.volumeInUse(by: fleet, neededBy: needed)?.container == "alpha")
        #expect(ContainersService.volumeInUse(by: fleet.reversed(), neededBy: needed)?.container == "alpha")
    }
}
