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

@testable import ContainerK8s

@Suite("k8s kubectl")
struct K8sKubectlTests {
    @Test("the bundled kubectl is the plugin's sibling")
    func siblingPath() {
        #expect(
            K8sKubectl.bundledKubectl(besides: "/App.app/Contents/libexec/container/plugins/k8s/bin/k8s")
                == "/App.app/Contents/libexec/container/plugins/k8s/bin/kubectl")
    }

    @Test("arguments pass through unchanged, after an optional --context, with the plugin's kubeconfig as the default")
    func passthrough() {
        let invocation = K8sKubectl.invocation(
            kubectl: "/k/kubectl",
            kubeconfig: "/home/.kube/config",
            inheritedKubeconfig: nil,
            context: "dev",
            arguments: ["get", "pods", "-A", "--context", "not-overridden"])
        #expect(invocation.executable == "/k/kubectl")
        #expect(invocation.argv == ["/k/kubectl", "--context", "dev", "get", "pods", "-A", "--context", "not-overridden"])
        #expect(invocation.environment == ["KUBECONFIG": "/home/.kube/config"])
    }

    @Test("a KUBECONFIG the user set is left alone")
    func userKubeconfigWins() {
        let invocation = K8sKubectl.invocation(
            kubectl: "/k/kubectl", kubeconfig: "/home/.kube/config", inheritedKubeconfig: "/mine", context: nil, arguments: ["version"])
        #expect(invocation.argv == ["/k/kubectl", "version"])
        #expect(invocation.environment.isEmpty)
    }
}
