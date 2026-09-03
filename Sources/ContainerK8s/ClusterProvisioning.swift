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

import ContainerizationError
import Logging
import TerminalProgress

extension K8sClusters {
    struct JoinCredentials: Sendable, Equatable {
        let token: String
        let caCertHash: String
    }

    struct WorkerNode: Sendable {
        let name: String
        let provisioner: any NodeProvisioner
    }

    typealias ControlPlaneInitializer =
        @Sendable (
            _ name: String,
            _ address: String,
            _ hasWorkers: Bool
        ) async throws -> JoinCredentials?

    /// Provision one control plane and its workers with deterministic rollback.
    ///
    /// A node is put in `attempted` before provisioning starts, because provisioning can
    /// create its container and then fail while booting it. Rollback runs workers-first and
    /// control-plane-last so each worker still has an API server while it is torn down.
    static func provisionCluster(
        name: String,
        controlPlane: any NodeProvisioner,
        workers: [WorkerNode],
        initializeControlPlane: @escaping ControlPlaneInitializer,
        finalizeCluster: @escaping @Sendable () async throws -> Void = {},
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws {
        var attempted: [(name: String, provisioner: any NodeProvisioner)] = []
        do {
            try Task.checkCancellation()
            attempted.append((name, controlPlane))
            await progressUpdate([.setDescription("Provisioning control plane")])
            try await controlPlane.provision(name: name, log: log)
            try Task.checkCancellation()
            let address = try await controlPlane.address(name: name, log: log)
            try Task.checkCancellation()
            let credentials = try await initializeControlPlane(name, address, !workers.isEmpty)
            try Task.checkCancellation()

            if !workers.isEmpty && credentials == nil {
                throw ContainerizationError(
                    .internalError,
                    message: "control plane did not provide worker join credentials")
            }

            for (index, worker) in workers.enumerated() {
                try Task.checkCancellation()
                attempted.append((worker.name, worker.provisioner))
                await progressUpdate([
                    .setDescription("Provisioning worker \(index + 1) of \(workers.count)")
                ])
                try await worker.provisioner.provision(name: worker.name, log: log)
                try Task.checkCancellation()
                let credentials = credentials!
                try await worker.provisioner.join(
                    name: worker.name,
                    controlPlaneEndpoint: "\(address):\(K8sHelper.clusterContainerPort)",
                    token: credentials.token,
                    caCertHash: credentials.caCertHash,
                    log: log)
                try Task.checkCancellation()
                try await worker.provisioner.waitForReady(name: worker.name, log: log)
            }
            try Task.checkCancellation()
            try await finalizeCluster()
            try Task.checkCancellation()
        } catch {
            let original = error
            for node in attempted.reversed() {
                do {
                    try await node.provisioner.teardown(name: node.name, log: log)
                } catch {
                    log.warning(
                        "failed to tear down node after cluster create failure",
                        metadata: ["node": "\(node.name)", "error": "\(error)"])
                }
            }
            throw original
        }
    }
}
