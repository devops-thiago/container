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
import ContainerizationError
import Foundation
import Logging

/// Following a control plane that came back with another address.
///
/// A node rewrites its own address in its own files when it boots with a new one, and that
/// is all it rewrites. What names the control plane's address from elsewhere is left as it
/// was: each worker's kubelet, and the two ConfigMaps kubeadm wrote the API server's
/// address into, of which kube-proxy reads one on every node. With those stale a worker
/// never reports Ready again, and no Service address is reachable, cluster DNS included.
///
/// Done from the host at every start rather than in the node's entrypoint: that script is
/// part of the node since its create, so nodes made by an earlier engine would never get it.
extension ClusterHelper {
    /// Any `server:` line naming the API server by IPv4 address. One naming it by host name
    /// follows the address already and is left alone.
    static let serverByAddress = "server: https://[0-9.]+:\(clusterContainerPort)"

    static func serverLine(address: String) -> String { "server: https://\(address):\(clusterContainerPort)" }

    /// Run in a worker. Points its kubelet at `address` and restarts it, printing `changed`,
    /// or does nothing when the kubelet already names it.
    static func workerEndpointScript(address: String, kubeletConfiguration: String = "/etc/kubernetes/kubelet.conf") -> String {
        """
        f='\(kubeletConfiguration)'
        want='\(serverLine(address: address))'
        [ -f "$f" ] || exit 0
        grep -Eq '\(serverByAddress)' "$f" || exit 0
        grep -Fq "$want" "$f" && exit 0
        updated=$(sed -E "s|\(serverByAddress)|$want|" "$f") || exit 1
        printf '%s\\n' "$updated" > "$f" || exit 1
        sync
        systemctl restart kubelet || exit 1
        echo changed
        """
    }

    /// Run in the control plane once its API server answers. Points the kubeconfigs kubeadm
    /// keeps in ConfigMaps at `address`, printing `changed <name>` for each one it rewrote,
    /// and restarts kube-proxy when its own was among them. A ConfigMap that is absent, as
    /// kube-proxy's is in a cluster made without it, is none of this script's business.
    static func controlPlaneEndpointScript(address: String) -> String {
        """
        want='\(serverLine(address: address))'
        k() { kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
        follow() {
            current=$(k -n "$1" get configmap "$2" -o yaml 2>/dev/null) || return 0
            printf '%s\\n' "$current" | grep -Eq '\(serverByAddress)' || return 0
            updated=$(printf '%s\\n' "$current" | sed -E "s|\(serverByAddress)|$want|")
            [ "$updated" = "$current" ] && return 0
            printf '%s\\n' "$updated" | k replace -f - >/dev/null || return 1
            echo "changed $2"
        }
        follow kube-public cluster-info || exit 1
        proxy=$(follow kube-system kube-proxy) || exit 1
        if [ -n "$proxy" ]; then
            echo "$proxy"
            k -n kube-system rollout restart daemonset/kube-proxy >/dev/null || exit 1
        fi
        """
    }

    /// Point everything in a started cluster that names the control plane's address at the
    /// one it has now. Costs one command per node when nothing moved.
    static func followControlPlane(name: String, workers: [String], client: ContainerClient, log: Logger) async throws {
        guard let address = try await client.get(id: name).networks.first?.ipv4Address.address.description else {
            throw ContainerizationError(.internalError, message: "control plane \(name) has no address")
        }
        try await waitForAPIServer(containerId: name, client: client, log: log)
        let nodes = [(name, controlPlaneEndpointScript(address: address))] + workers.map { ($0, workerEndpointScript(address: address)) }
        for (node, script) in nodes {
            try Task.checkCancellation()
            let result = try await execCapture(containerId: node, executable: "/bin/sh", arguments: ["-c", script], client: client)
            guard result.code == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message: "pointing \(node) at the control plane's address \(address) failed: \(result.output)")
            }
            let changed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !changed.isEmpty {
                log.info(
                    "control plane has a new address; node follows it",
                    metadata: ["node": "\(node)", "address": "\(address)", "changed": "\(changed.replacingOccurrences(of: "\n", with: ", "))"])
            }
        }
    }
}
