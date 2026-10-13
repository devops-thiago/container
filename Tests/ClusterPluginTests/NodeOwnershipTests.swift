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

import ContainerAPIClient
import ContainerResource
import Testing

@testable import ContainerK8s

struct NodeOwnershipTests {
    @Test("ownership metadata reaches control planes and workers without overriding reserved labels", arguments: [StandardRoles.controlPlane, StandardRoles.worker])
    func nodeCreationLabels(role: String) throws {
        let node = try LinuxNodeProvisioner(
            clusterName: "fixture", labels: ["owner": "this-run", ResourceLabelKeys.plugin: "wrong", ResourceLabelKeys.cluster: "wrong", ResourceLabelKeys.role: "wrong"],
            roles: [role])
        let labels = Utility.parseKeyValuePairs(node.managementLabels)
        #expect(labels["owner"] == "this-run")
        #expect(labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName)
        #expect(labels[ResourceLabelKeys.cluster] == "fixture")
        #expect(labels[ResourceLabelKeys.role] == role)
    }

    @Test("Kubernetes ownership options are repeatable and optional")
    func commandOptions() throws {
        #expect(try K8sCreate.parse([]).labels.isEmpty)
        #expect(try K8sDelete.parse([]).requiredLabels.isEmpty)
        #expect(try K8sCreate.parse(["--label", "owner=a", "--label", "purpose=b"]).labels == ["owner=a", "purpose=b"])
        #expect(try K8sDelete.parse(["--require-label", "owner=a", "--require-label", "purpose=b"]).requiredLabels == ["owner=a", "purpose=b"])
    }
}
