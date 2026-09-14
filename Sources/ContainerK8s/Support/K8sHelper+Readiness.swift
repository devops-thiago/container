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
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

extension K8sHelper {
    // MARK: - Readiness

    public static func runProbe(client: ContainerClient, containerId: String, arguments: [String]) async throws -> Int32 {
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        defer { try? devNull?.close() }
        let probe = ProcessConfiguration(
            executable: kubectlPath,
            arguments: arguments,
            environment: [kubeconfigEnv],
            terminal: false)
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: probe,
            stdio: [nil, devNull, devNull])
        try await proc.start()
        return try await proc.wait()
    }

    public static func waitForNodeBooted(containerId: String, client: ContainerClient, log: Logger) async throws {
        let timeout = 120
        log.info("Waiting for node to boot", metadata: ["node": "\(containerId)"])
        for attempt in 1...timeout {
            // Right after bootstrap the runtime client registers asynchronously, so a probe
            // can land while the container still reports stopped and the exec throws
            // invalidState — wrapped in the client's internalError, so the chain has to be
            // walked. That is "not booted yet", the very condition this loop waits out —
            // only the last attempt lets it escape as an error.
            let code: Int32
            do {
                code = try await execCapture(
                    containerId: containerId, executable: "/bin/sh",
                    arguments: ["-c", "test -S /run/containerd/containerd.sock"], client: client
                ).code
            } catch let error where attempt < timeout && Self.isContainerNotRunning(error) {
                code = -1
            }
            if code == 0 { return }
            if attempt == timeout {
                log.info("check container logs with 'container logs \(containerId)'")
                throw ContainerizationError(
                    .timeout,
                    message: "node \(containerId) did not boot within \(timeout * 2)s: containerd socket not present at /run/containerd/containerd.sock"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// How long a start waits for the control-plane node to report Ready, and then for
    /// CoreDNS to be Available, before it fails naming the step. Wall-clock, not probe
    /// counts: a probe is an exec into the node and takes several seconds of its own, so
    /// counting probes (180 and 300 of them, once) bounded nothing anyone could plan on —
    /// a cluster whose CoreDNS never came back after a node restart kept a start busy for
    /// three quarters of an hour.
    static let nodeReadyBudget: Duration = .seconds(300)
    static let podReadyBudget: Duration = .seconds(300)
    /// After this long without CoreDNS, its deployment is restarted once. Observed after a
    /// node stop and start: node Ready, coredns 0/1 for twenty minutes, pods restarted by
    /// kubelet twice; a fresh rollout is what brings it back.
    static let podRestartAfter: Duration = .seconds(120)

    static func waitForReady(containerId: String, client: ContainerClient, log: Logger) async throws {
        let clock = ContinuousClock()
        let nodeDeadline = clock.now.advanced(by: nodeReadyBudget)
        log.info("Waiting for control-plane node to become ready", metadata: ["budget": "\(nodeReadyBudget)"])
        while true {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Ready", "node", "--all", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { break }
            guard clock.now < nodeDeadline else {
                log.info("inspect node state with 'container exec \(containerId) kubectl get nodes -o wide'")
                throw ContainerizationError(
                    .timeout,
                    message:
                        "k8s cluster \(containerId): the control-plane node did not report Ready within \(Self.describe(nodeReadyBudget)); "
                        + "the nodes are running, so a later start may succeed — inspect with 'container exec \(containerId) kubectl get nodes -o wide'"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }

        let podStart = clock.now
        let podDeadline = podStart.advanced(by: podReadyBudget)
        var restartedCoreDNS = false
        log.info("Waiting for kube-system pods to become ready", metadata: ["budget": "\(podReadyBudget)"])
        while true {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Available", "deployment/coredns", "-n", "kube-system", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { return }
            if !restartedCoreDNS, clock.now >= podStart.advanced(by: podRestartAfter) {
                restartedCoreDNS = true
                log.info("coredns not Available after \(Self.describe(podRestartAfter)); restarting its deployment once")
                let restarted = try? await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["-n", "kube-system", "rollout", "restart", "deployment/coredns"])
                if restarted != 0 {
                    log.warning("coredns rollout restart did not succeed", metadata: ["code": "\(restarted.map(String.init) ?? "error")"])
                }
            }
            guard clock.now < podDeadline else {
                log.info("inspect pod state with 'container exec \(containerId) kubectl get pods -n kube-system'")
                throw ContainerizationError(
                    .timeout,
                    message:
                        "k8s cluster \(containerId): the node is Ready but CoreDNS did not become Available within \(Self.describe(podReadyBudget)); "
                        + "inspect with 'container exec \(containerId) kubectl get pods -n kube-system'"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func describe(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
    }

    static func isContainerNotRunning(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        while let containerization = current as? ContainerizationError {
            if containerization.code == .invalidState { return true }
            current = containerization.cause
        }
        return false
    }
}
