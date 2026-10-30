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

@testable import ContainerCluster

struct NodeOwnershipTests {
    @Test("ownership metadata reaches control planes and workers without overriding reserved labels", arguments: [StandardRoles.controlPlane, StandardRoles.worker])
    func nodeCreationLabels(role: String) throws {
        let node = try LinuxNodeProvisioner(
            clusterName: "fixture", labels: ["owner": "this-run", ResourceLabelKeys.plugin: "wrong", ResourceLabelKeys.cluster: "wrong", ResourceLabelKeys.role: "wrong"],
            roles: [role])
        let labels = Utility.parseKeyValuePairs(node.managementLabels)
        #expect(labels["owner"] == "this-run")
        #expect(labels[ResourceLabelKeys.plugin] == ClusterHelper.pluginName)
        #expect(labels[ResourceLabelKeys.cluster] == "fixture")
        #expect(labels[ResourceLabelKeys.role] == role)
    }

    @Test("legacy adoption is an explicit CLI option")
    func legacyAdoptionOption() throws {
        #expect(try ClusterStart.parse([]).adoptLegacy == false)
        #expect(try ClusterStart.parse(["--adopt-legacy"]).adoptLegacy)
    }

    @Test("Kubernetes ownership options are repeatable and optional")
    func commandOptions() throws {
        #expect(try ClusterCreate.parse([]).labels.isEmpty)
        #expect(try ClusterDelete.parse([]).requiredLabels.isEmpty)
        #expect(try ClusterCreate.parse(["--label", "owner=a", "--label", "purpose=b"]).labels == ["owner=a", "purpose=b"])
        #expect(try ClusterDelete.parse(["--require-label", "owner=a", "--require-label", "purpose=b"]).requiredLabels == ["owner=a", "purpose=b"])
    }

    @Test("nodes made under the plugin's earlier name, k8s, still belong to it; others do not")
    func legacyPluginName() throws {
        #expect(ClusterHelper.pluginName == "cluster")
        #expect(ClusterHelper.ownsNode([ResourceLabelKeys.plugin: "cluster"]))
        #expect(ClusterHelper.ownsNode([ResourceLabelKeys.plugin: "k8s"]))
        #expect(!ClusterHelper.ownsNode([ResourceLabelKeys.plugin: "machine"]))
        #expect(!ClusterHelper.ownsNode([:]))
        let pattern = try #require(ClusterHelper.nodeListFilters.labels[ResourceLabelKeys.plugin])
        let regex = try Regex(pattern)
        #expect("cluster".wholeMatch(of: regex) != nil)
        #expect("k8s".wholeMatch(of: regex) != nil)
        #expect("cluster2".wholeMatch(of: regex) == nil)
        #expect("machine".firstMatch(of: regex) == nil)
    }

    @Test("--workers is bounded, and --cni NONE needs no manifest file")
    func createOptions() throws {
        #expect(try ClusterCreate.parse(["--workers", "3"]).workers == 3)
        #expect(throws: (any Error).self) { try ClusterCreate.parse(["--workers", "\(K8sClusters.maximumWorkers + 1)"]) }
        #expect(try ClusterCreate.parse(["--cni", "NONE"]).cni == "NONE")
    }
}
