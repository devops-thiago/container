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

@testable import ContainerCluster

@Suite("k8s kubectl")
struct ClusterKubectlTests {
    @Test("the bundled kubectl is the plugin's sibling")
    func siblingPath() {
        #expect(
            ClusterKubectl.bundledKubectl(besides: "/App.app/Contents/libexec/container/plugins/cluster/bin/cluster")
                == "/App.app/Contents/libexec/container/plugins/cluster/bin/kubectl")
    }

    @Test("arguments pass through unchanged, after an optional --context, with the plugin's kubeconfig as the default")
    func passthrough() {
        let invocation = ClusterKubectl.invocation(
            kubectl: "/k/kubectl",
            kubeconfig: "/home/.kube/config",
            inheritedKubeconfig: nil,
            context: "dev",
            arguments: ["get", "pods", "-A", "--context", "not-overridden"])
        #expect(invocation.executable == "/k/kubectl")
        #expect(invocation.argv == ["/k/kubectl", "--context", "dev", "get", "pods", "-A", "--context", "not-overridden"])
        #expect(invocation.environment == ["KUBECONFIG": "/home/.kube/config"])
    }

    @Test("manifests, kustomizations, kubeconfigs and the local side of cp are host files")
    func fileReferences() {
        #expect(ClusterKubectl.fileReferences(in: ["apply", "-f", "deploy.yaml"]) == ["deploy.yaml"])
        #expect(ClusterKubectl.fileReferences(in: ["apply", "--filename=/abs/deploy.yaml", "-n", "x"]) == ["/abs/deploy.yaml"])
        #expect(ClusterKubectl.fileReferences(in: ["apply", "-k", "overlays/dev"]) == ["overlays/dev"])
        #expect(ClusterKubectl.fileReferences(in: ["--kubeconfig", "kc.yaml", "get", "pods"]) == ["kc.yaml"])
        #expect(ClusterKubectl.fileReferences(in: ["cp", "./local.txt", "web:/tmp/local.txt"]) == ["./local.txt"])
        #expect(ClusterKubectl.fileReferences(in: ["cp", "kube-system/web:/etc/hosts", "/Users/x/hosts", "-c", "main"]) == ["/Users/x/hosts"])
        #expect(ClusterKubectl.fileReferences(in: ["cp", "-n", "kube-system", "web:/etc/hosts", "./hosts"]) == ["./hosts"])
    }

    @Test("standard input, URLs and commands that name no file borrow nothing")
    func noFiles() {
        #expect(ClusterKubectl.fileReferences(in: ["apply", "-f", "-"]).isEmpty)
        #expect(ClusterKubectl.fileReferences(in: ["apply", "-f", "https://example.com/deploy.yaml"]).isEmpty)
        #expect(ClusterKubectl.fileReferences(in: ["get", "pods", "-A", "-o", "wide"]).isEmpty)
        #expect(ClusterKubectl.fileReferences(in: ["exec", "web", "--", "cat", "/etc/hosts"]).isEmpty)
    }

    @Test("a pod reference is a colon before any slash")
    func remoteCopyPaths() {
        #expect(ClusterKubectl.isRemoteCopyPath("web:/tmp/x"))
        #expect(ClusterKubectl.isRemoteCopyPath("kube-system/web:/tmp/x"))
        #expect(!ClusterKubectl.isRemoteCopyPath("/Users/x/file:with:colons"))
        #expect(!ClusterKubectl.isRemoteCopyPath("./dir/file"))
        #expect(!ClusterKubectl.isRemoteCopyPath("plain.txt"))
    }

    @Test("a KUBECONFIG the user set is left alone")
    func userKubeconfigWins() {
        let invocation = ClusterKubectl.invocation(
            kubectl: "/k/kubectl", kubeconfig: "/home/.kube/config", inheritedKubeconfig: "/mine", context: nil, arguments: ["version"])
        #expect(invocation.argv == ["/k/kubectl", "version"])
        #expect(invocation.environment.isEmpty)
    }
}
