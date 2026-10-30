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
import Testing

@testable import ContainerCluster

/// Containers take names longer than a hostname; a cluster does not, since its name is a node's
/// hostname and Kubernetes names the node by it.
struct K8sClusterNameTests {
    @Test func aClusterNameStaysWithinADNSLabel() {
        #expect(K8sClusters.nameValid(String(repeating: "k", count: 63)))
        #expect(!K8sClusters.nameValid(String(repeating: "k", count: 64)))
        #expect(ManagedContainer.nameValid(String(repeating: "k", count: 64)))
    }
}
