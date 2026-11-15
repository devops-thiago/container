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
            // A file named `fail-<what>` makes that command fail once, as it would in a node
            // where it cannot be done right now.
            try command(
                "systemctl",
                """
                echo "systemctl $*" >> '\(calls.path)'
                if [ -e '\(root.path)/fail-systemctl' ]; then rm '\(root.path)/fail-systemctl'; echo 'Job for kubelet.service failed' >&2; exit 1; fi
                """)
            // `get configmap <name> --ignore-not-found -o yaml` prints the stored one, or
            // nothing for one that is absent, as kubectl does; `replace -f -` stores what
            // it is given under the name it carries; anything else is recorded.
            try command(
                "kubectl",
                """
                maps='\(root.appendingPathComponent("configmaps").path)'
                shift 2
                case "$*" in
                *"get configmap"*)
                    if [ -e '\(root.path)/fail-get' ]; then echo 'The connection to the server 127.0.0.1:6443 was refused' >&2; exit 1; fi
                    case "$*" in *--ignore-not-found*) ;; *) [ -e "$maps/$5" ] || exit 1 ;; esac
                    [ ! -e "$maps/$5" ] || cat "$maps/$5" ;;
                "replace -f -") body=$(cat); name=$(printf '%s\\n' "$body" | sed -n 's/^  name: //p'); printf '%s\\n' "$body" > "$maps/$name" ;;
                *)
                    echo "kubectl $*" >> '\(calls.path)'
                    if [ -e '\(root.path)/fail-rollout' ]; then rm '\(root.path)/fail-rollout'; echo 'error: rollout failed' >&2; exit 1; fi ;;
                esac
                """)
        }

        var owed: String { root.appendingPathComponent("restart-owed").path }

        func fail(_ what: String) throws {
            try "".write(to: root.appendingPathComponent("fail-\(what)"), atomically: true, encoding: .utf8)
        }

        func worker(_ address: String) throws -> (code: Int32, output: String) {
            try run(ClusterHelper.workerEndpointScript(address: address, kubeletConfiguration: kubelet.path, restartOwed: owed))
        }

        func controlPlane(_ address: String) throws -> (code: Int32, output: String) {
            try run(ClusterHelper.controlPlaneEndpointScript(address: address, restartOwed: owed))
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
        let result = try node.worker("192.168.65.2")
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
        let result = try node.worker("192.168.64.2")
        #expect(result.code == 0)
        #expect(result.output.isEmpty)
        #expect(node.called().isEmpty)
    }

    /// An address that only begins like the wanted one is another address.
    @Test func workerOnALongerAddressIsNotTakenForTheSame() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.25:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.worker("192.168.64.2")
        #expect(result.output == "changed")
        #expect(try String(contentsOf: node.kubelet, encoding: .utf8) == kubeletConfiguration(server: "https://192.168.64.2:6443"))
    }

    /// A kubelet that names the control plane by host name follows it already.
    @Test func workerNamingTheControlPlaneByHostNameIsLeftAlone() throws {
        let node = try Node()
        defer { node.remove() }
        let named = kubeletConfiguration(server: "https://dev.test:6443")
        try named.write(to: node.kubelet, atomically: true, encoding: .utf8)
        let result = try node.worker("192.168.65.2")
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
        let result = try node.controlPlane("192.168.65.2")
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
        let result = try node.controlPlane("192.168.65.2")
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
        let result = try node.controlPlane("192.168.65.2")
        #expect(result.code == 0)
        #expect(result.output == "changed cluster-info")
        #expect(node.called().isEmpty)
    }

    /// The file was written and the restart then failed. The kubelet still runs on the
    /// previous address, so the next start has to restart it although the file is right.
    @Test func kubeletRestartThatFailedIsMadeAtTheNextStart() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.2:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        try node.fail("systemctl")
        let first = try node.worker("192.168.65.2")
        #expect(first.code == 1)
        #expect(first.output.contains("Job for kubelet.service failed"))
        #expect(try String(contentsOf: node.kubelet, encoding: .utf8) == kubeletConfiguration(server: "https://192.168.65.2:6443"))
        let second = try node.worker("192.168.65.2")
        #expect(second.code == 0)
        #expect(second.output == "restarted")
        #expect(node.called() == ["systemctl restart kubelet", "systemctl restart kubelet"])
        // Paid: a third start has nothing to do.
        let third = try node.worker("192.168.65.2")
        #expect(third.code == 0)
        #expect(third.output.isEmpty)
        #expect(node.called().count == 2)
    }

    /// The file keeps its mode through the rewrite, and no half-written copy is left.
    @Test func kubeletConfigurationKeepsItsModeAndLeavesNoCopy() throws {
        let node = try Node()
        defer { node.remove() }
        try kubeletConfiguration(server: "https://192.168.64.2:6443").write(to: node.kubelet, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: node.kubelet.path)
        #expect(try node.worker("192.168.65.2").code == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: node.kubelet.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!FileManager.default.fileExists(atPath: node.kubelet.path + ".new"))
        #expect(!FileManager.default.fileExists(atPath: node.owed))
    }

    /// The ConfigMap was replaced and the rollout then failed: kube-proxy still runs on the
    /// previous address, so the next start restarts it although the ConfigMap is right.
    @Test func kubeProxyRestartThatFailedIsMadeAtTheNextStart() throws {
        let node = try Node()
        defer { node.remove() }
        try node.configMap("cluster-info", server: "https://192.168.64.2:6443")
        try node.configMap("kube-proxy", server: "https://192.168.64.2:6443")
        try node.fail("rollout")
        let first = try node.controlPlane("192.168.65.2")
        #expect(first.code == 1)
        #expect(first.output.contains("error: rollout failed"))
        #expect(try node.configMap("kube-proxy").contains("server: https://192.168.65.2:6443"))
        let second = try node.controlPlane("192.168.65.2")
        #expect(second.code == 0)
        #expect(second.output == "restarted kube-proxy")
        let rollout = "kubectl -n kube-system rollout restart daemonset/kube-proxy"
        #expect(node.called() == [rollout, rollout])
        let third = try node.controlPlane("192.168.65.2")
        #expect(third.code == 0)
        #expect(third.output.isEmpty)
        #expect(node.called().count == 2)
    }

    /// Only a ConfigMap that is absent is passed over. One that cannot be read, with the
    /// API server refusing or the credentials not accepted, fails the script and says why.
    @Test func configMapThatCannotBeReadFailsTheScript() throws {
        let node = try Node()
        defer { node.remove() }
        try node.configMap("cluster-info", server: "https://192.168.64.2:6443")
        try node.configMap("kube-proxy", server: "https://192.168.64.2:6443")
        try node.fail("get")
        let result = try node.controlPlane("192.168.65.2")
        #expect(result.code == 1)
        #expect(result.output.contains("was refused"))
        #expect(try node.configMap("kube-proxy").contains("server: https://192.168.64.2:6443"))
        #expect(node.called().isEmpty)
    }
}
