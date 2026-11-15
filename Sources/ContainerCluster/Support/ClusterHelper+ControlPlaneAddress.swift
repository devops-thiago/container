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

    /// Where a node notes that a restart is owed: written before the configuration that
    /// calls for it, and removed once the restart went through. Without it a restart that
    /// failed would be forgotten, since the next start finds the configuration right.
    static let kubeletRestartOwed = "/etc/kubernetes/.kubelet-restart-owed"
    static let kubeProxyRestartOwed = "/etc/kubernetes/.kube-proxy-restart-owed"

    /// Run in a worker. Points its kubelet at `address` and restarts it, printing `changed`,
    /// or does nothing when the kubelet already names it and no restart is owed. A restart
    /// owed from a start that failed is made, printing `restarted`.
    static func workerEndpointScript(
        address: String, kubeletConfiguration: String = "/etc/kubernetes/kubelet.conf", restartOwed: String = kubeletRestartOwed
    ) -> String {
        """
        f='\(kubeletConfiguration)'
        owed='\(restartOwed)'
        want='\(serverLine(address: address))'
        [ -f "$f" ] || exit 0
        done=restarted
        if grep -Eq '\(serverByAddress)' "$f" && ! grep -Fq "$want" "$f"; then
            : > "$owed" || exit 1
            sync
            cp -p "$f" "$f.new" || exit 1
            sed -E "s|\(serverByAddress)|$want|" "$f" > "$f.new" || exit 1
            mv -f "$f.new" "$f" || exit 1
            sync
            done=changed
        fi
        [ -e "$owed" ] || exit 0
        systemctl restart kubelet || exit 1
        rm -f "$owed" || exit 1
        sync
        echo "$done"
        """
    }

    /// Run in the control plane once its API server answers. Points the kubeconfigs kubeadm
    /// keeps in ConfigMaps at `address`, printing `changed <name>` for each one it rewrote,
    /// and restarts kube-proxy when its own was among them, or when that restart is owed
    /// from a start that failed, printing `restarted kube-proxy`. A ConfigMap that is absent,
    /// as kube-proxy's is in a cluster made without it, is none of this script's business;
    /// one that cannot be read fails the script, with what kubectl said.
    static func controlPlaneEndpointScript(address: String, restartOwed: String = kubeProxyRestartOwed) -> String {
        """
        want='\(serverLine(address: address))'
        owed='\(restartOwed)'
        k() { kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
        follow() {
            current=$(k -n "$1" get configmap "$2" --ignore-not-found -o yaml) || return 1
            [ -n "$current" ] || return 0
            printf '%s\\n' "$current" | grep -Eq '\(serverByAddress)' || return 0
            updated=$(printf '%s\\n' "$current" | sed -E "s|\(serverByAddress)|$want|")
            [ "$updated" = "$current" ] && return 0
            if [ -n "$3" ]; then
                : > "$3" || return 1
                sync
            fi
            printf '%s\\n' "$updated" | k replace -f - >/dev/null || return 1
            echo "changed $2"
        }
        follow kube-public cluster-info || exit 1
        proxy=$(follow kube-system kube-proxy "$owed") || exit 1
        [ -z "$proxy" ] || echo "$proxy"
        [ -e "$owed" ] || exit 0
        k -n kube-system rollout restart daemonset/kube-proxy >/dev/null || exit 1
        rm -f "$owed" || exit 1
        sync
        [ -n "$proxy" ] || echo "restarted kube-proxy"
        """
    }

    /// How long a start gives the whole of this: the API server answering, and one command
    /// in each node.
    static let followBudget: Duration = .seconds(180)

    /// What following needs from the engine, so the order and the bounds can be tested.
    struct FollowOperations: Sendable {
        /// The control plane's address now.
        var address: @Sendable () async throws -> String?
        /// Returns once the API server answers, or throws at the deadline.
        var waitForAPIServer: @Sendable (ContinuousClock.Instant) async throws -> Void
        /// Runs a script in a node, bounded by the deadline.
        var run: @Sendable (_ node: String, _ script: String, ContinuousClock.Instant) async throws -> (code: Int32, output: String)
    }

    /// Point everything in a started cluster that names the control plane's address at the
    /// one it has now. Costs one command per node when nothing moved.
    static func followControlPlane(name: String, workers: [String], client: ContainerClient, log: Logger) async throws {
        try await followControlPlane(
            name: name, workers: workers, log: log,
            operations: FollowOperations(
                address: { try await client.get(id: name).networks.first?.ipv4Address.address.description },
                waitForAPIServer: { try await waitForAPIServer(containerId: name, client: client, log: log, deadline: $0) },
                run: { node, script, deadline in
                    try await execCapture(
                        containerId: node, executable: "/bin/sh", arguments: ["-c", script], client: client, deadline: deadline)
                }))
    }

    /// One deadline covers the whole stage. A node command that has not ended by then is
    /// killed and the start fails; a cancellation ends the one in flight at once.
    static func followControlPlane(
        name: String, workers: [String], log: Logger, operations: FollowOperations, budget: Duration = followBudget,
        now: @Sendable () -> ContinuousClock.Instant = { .now }
    ) async throws {
        let deadline = now().advanced(by: budget)
        func check() throws {
            try Task.checkCancellation()
            guard now() < deadline else {
                throw ContainerizationError(
                    .timeout, message: "cluster \(name): pointing its nodes at the control plane's address took more than \(Int(budget.components.seconds))s")
            }
        }
        try check()
        guard let address = try await operations.address() else {
            throw ContainerizationError(.internalError, message: "control plane \(name) has no address")
        }
        try check()
        try await operations.waitForAPIServer(deadline)
        let nodes = [(name, controlPlaneEndpointScript(address: address))] + workers.map { ($0, workerEndpointScript(address: address)) }
        for (node, script) in nodes {
            try check()
            let result: (code: Int32, output: String)
            do {
                result = try await operations.run(node, script, deadline)
            } catch {
                try check()
                throw error
            }
            try check()
            guard result.code == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message: "pointing \(node) at the control plane's address \(address) failed: \(result.output)")
            }
            // Stderr comes back with stdout, so a warning is not taken for a change.
            let changed = result.output.split(separator: "\n").filter { $0.hasPrefix("changed") || $0.hasPrefix("restarted") }
            if !changed.isEmpty {
                log.info(
                    "control plane has a new address; node follows it",
                    metadata: ["node": "\(node)", "address": "\(address)", "changed": "\(changed.joined(separator: ", "))"])
            }
        }
    }
}
