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

import ContainerCommands
import ContainerResource
import Testing

// MARK: - ManagedContainer conformance tests

struct ManagedContainerDisplayTests {
    @Test
    func tableHeaderHasElevenColumns() {
        #expect(ManagedContainer.tableHeader.count == 11)
        #expect(ManagedContainer.tableHeader[0] == "ID")
        #expect(ManagedContainer.tableHeader[4] == "STATE")
        #expect(ManagedContainer.tableHeader[5] == "HEALTH", "left of IP, which can be empty")
        #expect(ManagedContainer.tableHeader[9] == "STARTED")
        #expect(ManagedContainer.tableHeader[10] == "RESTARTS", "still last, for scripts that count from the right")
    }

    @Test
    func healthIsNoneWithoutACheckAndTheStatusWithOne() {
        let image = ImageDescription(
            reference: "docker.io/library/nginx:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0),
            supplementalGroups: [], rlimits: [])
        let configuration = ContainerConfiguration(id: "web", image: image, process: process)

        let unchecked = ManagedContainer(configuration: configuration, status: ContainerStatus(state: .running, networks: []))
        #expect(unchecked.tableRow[5] == "none")

        for status in HealthStatus.allCases {
            let checked = ManagedContainer(
                configuration: configuration,
                status: ContainerStatus(state: .running, networks: [], health: ContainerHealth(status: status)))
            #expect(checked.tableRow[5] == status.rawValue)
            #expect(checked.tableRow.count == ManagedContainer.tableHeader.count)
        }
    }
}

// MARK: - NetworkResource ListDisplayable conformance tests

struct NetworkResourceDisplayTests {
    @Test
    func tableHeaderHasTwoColumns() {
        #expect(NetworkResource.tableHeader.count == 2)
        #expect(NetworkResource.tableHeader == ["NETWORK", "SUBNET"])
    }
}
