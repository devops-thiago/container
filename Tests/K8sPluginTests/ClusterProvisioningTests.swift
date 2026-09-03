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

import Logging
import Testing

@testable import ContainerK8s

private actor ProvisioningEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private enum ProvisioningStep: Sendable, Equatable {
    case provision
    case address
    case join
    case ready
    case teardown
}

private enum ProvisioningFailure: Error { case expected }

private struct TestProvisioner: NodeProvisioner {
    let label: String
    let roles: [String]
    let events: ProvisioningEvents
    let failAt: ProvisioningStep?

    init(
        _ label: String,
        roles: [String],
        events: ProvisioningEvents,
        failAt: ProvisioningStep? = nil
    ) {
        self.label = label
        self.roles = roles
        self.events = events
        self.failAt = failAt
    }

    func provision(name: String, log: Logger) async throws {
        await events.append("\(label).provision:\(name)")
        if failAt == .provision { throw ProvisioningFailure.expected }
    }

    func address(name: String, log: Logger) async throws -> String {
        await events.append("\(label).address:\(name)")
        if failAt == .address { throw ProvisioningFailure.expected }
        return "10.0.0.2"
    }

    func join(
        name: String,
        controlPlaneEndpoint: String,
        token: String,
        caCertHash: String,
        log: Logger
    ) async throws {
        await events.append(
            "\(label).join:\(name):\(controlPlaneEndpoint):\(token):\(caCertHash)")
        if failAt == .join { throw ProvisioningFailure.expected }
    }

    func waitForReady(name: String, log: Logger) async throws {
        await events.append("\(label).ready:\(name)")
        if failAt == .ready { throw ProvisioningFailure.expected }
    }

    func teardown(name: String, log: Logger) async throws {
        await events.append("\(label).teardown:\(name)")
        if failAt == .teardown { throw ProvisioningFailure.expected }
    }
}

@Suite("Kubernetes worker provisioning")
struct ClusterProvisioningTests {
    private let log = Logger(label: "cluster-provisioning-tests")

    @Test("workers join the observed control-plane endpoint and each reaches readiness")
    func workersJoinAndBecomeReady() async throws {
        let events = ProvisioningEvents()
        let controlPlane = TestProvisioner(
            "cp", roles: [StandardRoles.controlPlane], events: events)
        let workers = [1, 2].map { index in
            K8sClusters.WorkerNode(
                name: "dev-worker-\(index)",
                provisioner: TestProvisioner(
                    "w\(index)", roles: [StandardRoles.worker], events: events))
        }

        try await K8sClusters.provisionCluster(
            name: "dev",
            controlPlane: controlPlane,
            workers: workers,
            initializeControlPlane: { name, address, hasWorkers in
                await events.append("init:\(name):\(address):\(hasWorkers)")
                return .init(token: "token", caCertHash: "sha256:hash")
            },
            log: log)

        #expect(
            await events.values == [
                "cp.provision:dev",
                "cp.address:dev",
                "init:dev:10.0.0.2:true",
                "w1.provision:dev-worker-1",
                "w1.join:dev-worker-1:10.0.0.2:6443:token:sha256:hash",
                "w1.ready:dev-worker-1",
                "w2.provision:dev-worker-2",
                "w2.join:dev-worker-2:10.0.0.2:6443:token:sha256:hash",
                "w2.ready:dev-worker-2",
            ])
    }

    @Test("a worker readiness failure tears down attempted nodes in reverse order")
    func readinessFailureCleansUpAllAttemptedNodes() async {
        let events = ProvisioningEvents()
        let controlPlane = TestProvisioner(
            "cp", roles: [StandardRoles.controlPlane], events: events)
        let workers = [
            K8sClusters.WorkerNode(
                name: "dev-worker-1",
                provisioner: TestProvisioner(
                    "w1", roles: [StandardRoles.worker], events: events)),
            K8sClusters.WorkerNode(
                name: "dev-worker-2",
                provisioner: TestProvisioner(
                    "w2", roles: [StandardRoles.worker], events: events, failAt: .ready)),
        ]

        await #expect(throws: ProvisioningFailure.self) {
            try await K8sClusters.provisionCluster(
                name: "dev",
                controlPlane: controlPlane,
                workers: workers,
                initializeControlPlane: { _, _, _ in
                    .init(token: "token", caCertHash: "sha256:hash")
                },
                log: log)
        }

        let recorded = await events.values
        #expect(
            recorded.suffix(3) == [
                "w2.teardown:dev-worker-2",
                "w1.teardown:dev-worker-1",
                "cp.teardown:dev",
            ])
    }
}
