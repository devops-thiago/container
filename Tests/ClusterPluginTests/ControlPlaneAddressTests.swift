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

import Foundation
import Testing

@testable import ContainerCluster

/// The scripts a start runs in the nodes to follow a control plane to a new address, run
/// here as they are against files, with `systemctl` and `kubectl` stood in for.
struct ControlPlaneAddressTests {
    /// A directory holding stand-ins for the node's commands and what they were asked to do.
    private struct Node {
        let root: URL
        var calls: URL { root.appendingPathComponent("calls") }
        var kubelet: URL { root.appendingPathComponent("kubelet.conf") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cp-address-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("configmaps"), withIntermediateDirectories: true)
            try command("systemctl", "echo \"systemctl $*\" >> '\(calls.path)'")
            // `get configmap <name> -o yaml` prints the stored one or fails; `replace -f -`
            // stores what it is given under the name it carries; anything else is recorded.
            try command(
                "kubectl",
                """
                maps='\(root.appendingPathComponent("configmaps").path)'
                shift 2
                case "$*" in
                *"get configmap"*) cat "$maps/$5" 2>/dev/null || exit 1 ;;
                "replace -f -") body=$(cat); name=$(printf '%s\\n' "$body" | sed -n 's/^  name: //p'); printf '%s\\n' "$body" > "$maps/$name" ;;
                *) echo "kubectl $*" >> '\(calls.path)' ;;
                esac
                """)
        }

        private func command(_ name: String, _ body: String) throws {
            let file = root.appendingPathComponent("bin/\(name)")
            try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func configMap(_ name: String, server: String?) throws {
            let line = server.map { "    server: \($0)\n" } ?? ""
            try "apiVersion: v1\ndata:\n  kubeconfig: |\n\(line)kind: ConfigMap\nmetadata:\n  name: \(name)\n"
                .write(to: root.appendingPathComponent("configmaps/\(name)"), atomically: true, encoding: .utf8)
        }

        func configMap(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("configmaps/\(name)"), encoding: .utf8)
        }

        func called() -> [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func run(_ script: String) throws -> (code: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["PATH": "\(root.appendingPathComponent("bin").path):/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func kubeletConfiguration(server: String) -> String {
        "clusters:\n- cluster:\n    certificate-authority-data: abc\n    server: \(server)\n  name: dev\n"
    }

    @Test func workerOnThePreviousAddressIsPointedAtTheNewOneAndItsKubeletRestarted() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.2:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.run(ClusterHelper.workerEndpointScript(address: "192.168.65.2", kubeletConfiguration: node.kubelet.path))
        #expect(result.code == 0)
        #expect(result.output == "changed")
        #expect(try String(contentsOf: node.kubelet, encoding: .utf8) == kubeletConfiguration(server: "https://192.168.65.2:6443"))
        #expect(node.called() == ["systemctl restart kubelet"])
    }

    /// The ordinary start: nothing moved, so nothing is written and the kubelet is left running.
    @Test func workerAlreadyOnTheAddressIsLeftAlone() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.2:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.run(ClusterHelper.workerEndpointScript(address: "192.168.64.2", kubeletConfiguration: node.kubelet.path))
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(node.called().isEmpty)
    }

    /// An address that only begins like the wanted one is another address.
    @Test func workerOnALongerAddressIsNotTakenForTheSame() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.25:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.run(ClusterHelper.workerEndpointScript(address: "192.168.64.2", kubeletConfiguration: node.kubelet.path))
        #expect(result.output == "changed")
        #expect(try String(contentsOf: node.kubelet, encoding: .utf8) == kubeletConfiguration(server: "https://192.168.64.2:6443"))
    }

    /// A kubelet that names the control plane by host name follows it already.
    @Test func workerNamingTheControlPlaneByHostNameIsLeftAlone() throws {
        let node = try Node()
        defer { node.remove() }
        let named = kubeletConfiguration(server: "https://dev.test:6443")
        try named.write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.run(ClusterHelper.workerEndpointScript(address: "192.168.65.2", kubeletConfiguration: node.kubelet.path))
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(try String(contentsOf: node.kubelet, encoding: .utf8) == named)
        #expect(node.called().isEmpty)
    }

    @Test func controlPlaneRewritesBothConfigMapsAndRestartsKubeProxy() throws {
        let node = try Node()
        defer { node.remove() }
        try node.configMap("cluster-info", server: "https://192.168.64.2:6443")
        try node.configMap("kube-proxy", server: "https://192.168.64.2:6443")
        let result = try node.run(ClusterHelper.controlPlaneEndpointScript(address: "192.168.65.2"))
        #expect(result.code == 0)
        #expect(result.output == "changed cluster-info\nchanged kube-proxy")
        #expect(try node.configMap("cluster-info").contains("server: https://192.168.65.2:6443"))
        #expect(try node.configMap("kube-proxy").contains("server: https://192.168.65.2:6443"))
        #expect(node.called() == ["kubectl -n kube-system rollout restart daemonset/kube-proxy"])
    }

    @Test func controlPlaneOnTheSameAddressChangesNothing() throws {
        let node = try Node()
        defer { node.remove() }
        try node.configMap("cluster-info", server: "https://192.168.65.2:6443")
        try node.configMap("kube-proxy", server: "https://192.168.65.2:6443")
        let before = try node.configMap("kube-proxy")
        let result = try node.run(ClusterHelper.controlPlaneEndpointScript(address: "192.168.65.2"))
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(try node.configMap("kube-proxy") == before)
        #expect(node.called().isEmpty)
    }

    /// kube-proxy is restarted for its own ConfigMap only, and a cluster without one is fine.
    @Test func clusterWithoutKubeProxyStillFollowsInClusterInfo() throws {
        let node = try Node()
        defer { node.remove() }
        try node.configMap("cluster-info", server: "https://192.168.64.2:6443")
        let result = try node.run(ClusterHelper.controlPlaneEndpointScript(address: "192.168.65.2"))
        #expect(result.code == 0)
        #expect(result.output == "changed cluster-info")
        #expect(node.called().isEmpty)
    }
}
