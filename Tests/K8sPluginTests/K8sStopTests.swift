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
import ContainerizationError
import Foundation
import Logging
import Synchronization
import Testing

@testable import ContainerK8s

private func snapshot(
    id: String,
    cluster: String,
    role: String,
    status: String = "running",
    incarnation: String
) throws -> ContainerSnapshot {
    let labels = [
        ResourceLabelKeys.plugin: K8sHelper.pluginName,
        ResourceLabelKeys.cluster: cluster,
        ResourceLabelKeys.role: role,
    ]
    let labelsJSON = try String(decoding: JSONEncoder().encode(labels), as: UTF8.self)
    let sha = "sha256:" + String(repeating: "a", count: 64)
    let json = """
        {
            "configuration": {
                "id": "\(id)",
                "image": {"reference":"img:latest","descriptor":{"mediaType":"m","digest":"\(sha)","size":1}},
                "runtimeHandler": "container-runtime-linux",
                "platform": {"os":"linux","architecture":"arm64"},
                "initProcess": {"executable":"/bin/sh","arguments":[],"environment":[],"workingDirectory":"/","terminal":false,"user":{"id":{"uid":0,"gid":0}},"rlimits":[],"supplementalGroups":[]},
                "resources": {"cpus":2,"memoryInBytes":2147483648},
                "labels": \(labelsJSON)
            },
            "incarnation": "\(incarnation)",
            "status": "\(status)",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

/// The engine as `stop` sees it: a listing, and stops that record what they were asked to
/// act on and refuse, as the service does, a label or incarnation that no longer matches.
private final class StoppableContainers: K8sClusterContainers, @unchecked Sendable {
    struct Call: Equatable {
        let id: String
        let labels: [String: String]
        let incarnation: String
    }

    private let state: Mutex<(listed: [ContainerSnapshot], current: [String: ContainerSnapshot], calls: [Call])>

    init(listed: [ContainerSnapshot], current: [ContainerSnapshot]? = nil) {
        let now = current ?? listed
        state = Mutex((listed, Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) }), []))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func get(id: String) async throws -> ContainerSnapshot {
        try state.withLock { state in
            guard let snapshot = state.current[id] else {
                throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
            }
            return snapshot
        }
    }

    func listNodes() async throws -> [ContainerSnapshot] {
        state.withLock { $0.listed }
    }

    func stop(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {
        try state.withLock { state in
            guard let current = state.current[id] else {
                throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
            }
            guard requiredLabels.allSatisfy({ current.configuration.labels[$0.key] == $0.value }),
                current.incarnation == expectedIncarnation
            else {
                throw ContainerizationError(.invalidArgument, message: "container \(id) is not what this operation observed")
            }
            state.calls.append(Call(id: id, labels: requiredLabels, incarnation: expectedIncarnation))
        }
    }

    func delete(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {
        Issue.record("stop must not delete \(id)")
    }
}

@Suite("k8s stop")
struct K8sStopTests {
    private let log = Logger(label: "k8s-stop-tests")

    @Test("workers stop before the control plane, each with the labels and incarnation observed")
    func workersStopFirst() async throws {
        let name = "dev"
        let controlPlane = try snapshot(id: name, cluster: name, role: K8sHelper.controlPlaneRoleName, incarnation: "cp")
        let worker1 = try snapshot(id: "\(name)-worker-1", cluster: name, role: K8sHelper.workerRoleName, incarnation: "w1")
        let worker2 = try snapshot(id: "\(name)-worker-2", cluster: name, role: K8sHelper.workerRoleName, incarnation: "w2")
        let other = try snapshot(id: "other", cluster: "other", role: K8sHelper.controlPlaneRoleName, incarnation: "o")
        let engine = StoppableContainers(listed: [worker1, other, controlPlane, worker2])

        try await K8sClusters.stop(name: name, containers: engine, log: log)

        let expectedLabels = [
            ResourceLabelKeys.plugin: K8sHelper.pluginName,
            ResourceLabelKeys.cluster: name,
        ]
        #expect(
            engine.calls == [
                .init(id: "\(name)-worker-2", labels: expectedLabels, incarnation: "w2"),
                .init(id: "\(name)-worker-1", labels: expectedLabels, incarnation: "w1"),
                .init(id: name, labels: expectedLabels, incarnation: "cp"),
            ])
    }

    @Test("a node that is already stopped is left alone")
    func stoppedNodesAreSkipped() async throws {
        let name = "dev"
        let controlPlane = try snapshot(id: name, cluster: name, role: K8sHelper.controlPlaneRoleName, incarnation: "cp")
        let worker = try snapshot(
            id: "\(name)-worker-1", cluster: name, role: K8sHelper.workerRoleName, status: "stopped", incarnation: "w1")
        let engine = StoppableContainers(listed: [controlPlane, worker])

        try await K8sClusters.stop(name: name, containers: engine, log: log)

        #expect(engine.calls.map(\.id) == [name])
    }

    @Test("a name that is not a cluster is refused before any stop")
    func unknownClusterIsRefused() async throws {
        let other = try snapshot(id: "other", cluster: "other", role: K8sHelper.controlPlaneRoleName, incarnation: "o")
        let engine = StoppableContainers(listed: [other])

        await #expect(throws: ContainerizationError.self) {
            try await K8sClusters.stop(name: "dev", containers: engine, log: log)
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("a node replaced between the listing and the stop is refused, and the rest are not stopped")
    func replacedNodeStopsTheRun() async throws {
        let name = "dev"
        let controlPlane = try snapshot(id: name, cluster: name, role: K8sHelper.controlPlaneRoleName, incarnation: "cp")
        let worker = try snapshot(id: "\(name)-worker-1", cluster: name, role: K8sHelper.workerRoleName, incarnation: "w1")
        let replacement = try snapshot(id: "\(name)-worker-1", cluster: name, role: K8sHelper.workerRoleName, incarnation: "w1-again")
        let engine = StoppableContainers(listed: [controlPlane, worker], current: [controlPlane, replacement])

        await #expect(throws: ContainerizationError.self) {
            try await K8sClusters.stop(name: name, containers: engine, log: log)
        }
        #expect(engine.calls.isEmpty, "the control plane was not stopped under a worker that is not ours")
    }
}
