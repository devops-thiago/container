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

// MARK: - Fixtures

private func snapshot(
    id: String,
    labels: [String: String],
    incarnation: String = "incarnation"
) throws -> ContainerSnapshot {
    let labelsJSON = try String(decoding: JSONEncoder().encode(labels), as: UTF8.self)
    let sha = "sha256:" + String(repeating: "a", count: 64)
    let json = """
        {
            "configuration": {
                "id": "\(id)",
                "image": {
                    "reference": "docker.io/kindest/node:v1.35.5",
                    "descriptor": {"mediaType":"","digest":"\(sha)","size":0}
                },
                "initProcess": {"executable":"/bin/sh","arguments":[],"environment":[],"workingDirectory":"/","terminal":false,"user":{"id":{"uid":0,"gid":0}},"supplementalGroups":[],"rlimits":[]},
                "resources": {"cpus":2,"memoryInBytes":2147483648},
                "labels": \(labelsJSON)
            },
            "incarnation": "\(incarnation)",
            "status": "running",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private let nodeLabels = ["com.apple.container.plugin": "k8s", "com.apple.container.resource.role": "control-plane"]
private let ordinaryLabels = ["app": "web"]

/// Stands in for the engine. `current` is what each ID names *now*; stop and delete
/// require both ownership labels and the exact observed incarnation.
private final class FakeContainers: K8sClusterContainers, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let id: String
        let labels: [String: String]
        let incarnation: String
    }

    private typealias State = (
        getResult: Result<ContainerSnapshot, Error>,
        listed: [ContainerSnapshot],
        current: [String: ContainerSnapshot],
        calls: [Call]
    )
    private let state: Mutex<State>
    private let beforeMutation: (@Sendable () async -> Void)?

    init(
        get: Result<ContainerSnapshot, Error>,
        current: ContainerSnapshot?,
        listed: [ContainerSnapshot]? = nil,
        beforeMutation: (@Sendable () async -> Void)? = nil
    ) {
        self.beforeMutation = beforeMutation
        let defaultList: [ContainerSnapshot]
        switch get {
        case .success(let snapshot): defaultList = [snapshot]
        case .failure: defaultList = []
        }
        state = Mutex(
            (
                get,
                listed ?? defaultList,
                current.map { [$0.id: $0] } ?? [:],
                []
            ))
    }

    init(
        get: Result<ContainerSnapshot, Error>,
        listed: [ContainerSnapshot],
        current: [ContainerSnapshot]
    ) {
        self.beforeMutation = nil
        state = Mutex(
            (
                get,
                listed,
                Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }),
                []
            ))
    }

    init(controlPlane: ContainerSnapshot, workers: [ContainerSnapshot]) {
        self.beforeMutation = nil
        let all = [controlPlane] + workers
        state = Mutex(
            (
                .success(controlPlane),
                all,
                Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }),
                []
            ))
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var current: ContainerSnapshot? { state.withLock { $0.current.values.first } }
    var currentIDs: Set<String> { state.withLock { Set($0.current.keys) } }

    /// The race under test: between the caller's lookup and its mutation, the ID comes to
    /// name something else.
    func replace(with replacement: ContainerSnapshot) {
        state.withLock { $0.current[replacement.id] = replacement }
    }

    func get(id: String) async throws -> ContainerSnapshot {
        try state.withLock { try $0.getResult.get() }
    }

    func listNodes() async throws -> [ContainerSnapshot] {
        state.withLock { $0.listed }
    }

    func stop(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws {
        if let beforeMutation { await beforeMutation() }
        try mutate(
            "stop", id: id, requiredLabels: requiredLabels,
            expectedIncarnation: expectedIncarnation
        ) { _ in }
    }

    func delete(
        id: String, requiredLabels: [String: String], expectedIncarnation: String
    ) async throws {
        try mutate(
            "delete", id: id, requiredLabels: requiredLabels,
            expectedIncarnation: expectedIncarnation
        ) { $0 = nil }
    }

    private func mutate(
        _ name: String,
        id: String,
        requiredLabels: [String: String],
        expectedIncarnation: String,
        _ apply: (inout ContainerSnapshot?) -> Void
    ) throws {
        try state.withLock { state in
            guard let current = state.current[id] else {
                throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
            }
            guard requiredLabels.allSatisfy({ current.configuration.labels[$0.key] == $0.value }) else {
                throw ContainerizationError(.invalidArgument, message: "container \(id) does not carry the labels this operation requires")
            }
            guard current.incarnation == expectedIncarnation else {
                throw ContainerizationError(.invalidArgument, message: "container \(id) is not the observed incarnation")
            }
            state.calls.append(
                Call(
                    name: name,
                    id: id,
                    labels: requiredLabels,
                    incarnation: expectedIncarnation))
            var target: ContainerSnapshot? = current
            apply(&target)
            state.current[id] = target
        }
    }
}

private actor MutationBarrier {
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var arrived = false

    func wait() async {
        arrived = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

private func withScratchKubeconfig(containing cluster: String?, _ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("k8s-delete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config")
    if let cluster {
        let yaml = """
            apiVersion: v1
            kind: Config
            clusters:
            - name: \(cluster)
              cluster:
                server: https://127.0.0.1:6443
            contexts:
            - name: \(cluster)
              context:
                cluster: \(cluster)
                user: \(cluster)
            users:
            - name: \(cluster)
              user:
                token: not-a-real-token
            current-context: \(cluster)
            """
        try yaml.write(to: file, atomically: true, encoding: .utf8)
    }
    let key = "KUBECONFIG"
    let original = Darwin.getenv(key).map { String(cString: $0) }
    setenv(key, file.path, 1)
    defer {
        if let original { setenv(key, original, 1) } else { unsetenv(key) }
    }
    try await body(file)
}

private let log = Logger(label: "k8s-delete-tests")

// MARK: - Tests

extension KubeconfigEnvTests {
    /// `K8sClusters.delete` against the engine it validates and then mutates by ID.
    @Suite("K8sClusters.delete")
    struct K8sDeleteTests {
        @Test("a lookup that fails performs no stop and no delete")
        func transientLookupFailureFailsClosed() async throws {
            let name = "cluster-a"
            let engine = FakeContainers(
                get: .failure(ContainerizationError(.internalError, message: "XPC timeout")),
                current: try snapshot(id: name, labels: nodeLabels))
            try await withScratchKubeconfig(containing: name) { file in
                await #expect(throws: ContainerizationError.self) {
                    try await K8sClusters.delete(name: name, containers: engine, log: log)
                }
                #expect(engine.calls.isEmpty, "nothing may be stopped or deleted on a failed read")
                #expect(engine.current != nil, "the container is untouched")
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(yaml.contains("name: \(name)"), "the kubeconfig context is kept until the delete happens")
            }
        }

        @Test("an ordinary container with the requested ID is refused without mutation")
        func ordinaryContainerIsRefused() async throws {
            let name = "web"
            let engine = FakeContainers(
                get: .success(try snapshot(id: name, labels: ordinaryLabels)),
                current: try snapshot(id: name, labels: ordinaryLabels))
            try await withScratchKubeconfig(containing: nil) { _ in
                await #expect(throws: ContainerizationError.self) {
                    try await K8sClusters.delete(name: name, containers: engine, log: log)
                }
                #expect(engine.calls.isEmpty)
                #expect(engine.current != nil)
            }
        }

        @Test("a same-ID replacement made after validation survives")
        func replacementAfterValidationSurvives() async throws {
            let name = "cluster-b"
            let node = try snapshot(id: name, labels: nodeLabels)
            let engine = FakeContainers(get: .success(node), current: node)
            // Validated as a node; by the time the stop runs, the ID names a plain container.
            engine.replace(with: try snapshot(id: name, labels: ordinaryLabels))
            try await withScratchKubeconfig(containing: name) { file in
                await #expect(throws: ContainerizationError.self) {
                    try await K8sClusters.delete(name: name, containers: engine, log: log)
                }
                #expect(engine.calls.isEmpty, "the refusal happens before any recorded mutation")
                #expect(engine.current?.configuration.labels == ordinaryLabels, "the replacement is still there")
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(yaml.contains("name: \(name)"), "and its kubeconfig context was not removed either")
            }
        }

        @Test("a definite not-found skips to the kubeconfig cleanup")
        func notFoundOnlyCleansTheKubeconfig() async throws {
            let name = "cluster-gone"
            let engine = FakeContainers(
                get: .failure(ContainerizationError(.notFound, message: "container with ID \(name) not found")),
                current: nil)
            try await withScratchKubeconfig(containing: name) { file in
                try await K8sClusters.delete(name: name, containers: engine, log: log)
                #expect(engine.calls.isEmpty)
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(!yaml.contains("name: \(name)"))
            }
        }

        @Test("surviving workers are deleted when the control plane is already gone")
        func orphanedWorkersAreDeleted() async throws {
            let name = "cluster-orphaned-workers"
            let worker = try snapshot(
                id: "\(name)-worker-1",
                labels: [
                    ResourceLabelKeys.plugin: K8sHelper.pluginName,
                    ResourceLabelKeys.cluster: name,
                    ResourceLabelKeys.role: K8sHelper.workerRoleName,
                ],
                incarnation: "worker-token")
            let engine = FakeContainers(
                get: .failure(
                    ContainerizationError(
                        .notFound,
                        message: "container with ID \(name) not found")),
                listed: [worker],
                current: [worker])

            try await withScratchKubeconfig(containing: name) { file in
                await #expect(throws: ContainerizationError.self) {
                    try await K8sClusters.delete(
                        name: name,
                        expectedControlPlaneIncarnation: "selected-predecessor",
                        containers: engine,
                        log: log)
                }
                #expect(engine.calls.isEmpty)
                #expect(engine.currentIDs == [worker.id])
                #expect(try String(contentsOf: file, encoding: .utf8).contains("name: \(name)"))

                try await K8sClusters.delete(name: name, containers: engine, log: log)
                #expect(
                    engine.calls.map { "\($0.name):\($0.id):\($0.incarnation)" } == [
                        "stop:\(worker.id):worker-token",
                        "delete:\(worker.id):worker-token",
                    ])
                #expect(engine.currentIDs.isEmpty)
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(!yaml.contains("name: \(name)"))
            }
        }

        @Test("a same-label same-ID replacement at the mutation barrier is rejected by incarnation")
        func sameLabelReplacementSurvives() async throws {
            let name = "cluster-token"
            let observed = try snapshot(
                id: name, labels: nodeLabels, incarnation: "observed")
            let barrier = MutationBarrier()
            let engine = FakeContainers(
                get: .success(observed),
                current: observed,
                beforeMutation: { await barrier.wait() })

            try await withScratchKubeconfig(containing: name) { file in
                let deletion = Task {
                    try await K8sClusters.delete(name: name, containers: engine, log: log)
                }
                await barrier.waitForArrival()
                engine.replace(
                    with: try snapshot(
                        id: name, labels: nodeLabels, incarnation: "replacement"))
                await barrier.open()
                await #expect(throws: ContainerizationError.self) {
                    try await deletion.value
                }
                #expect(engine.calls.isEmpty)
                #expect(engine.current?.incarnation == "replacement")
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(yaml.contains("name: \(name)"))
            }
        }

        @Test("a mismatched selected control-plane incarnation fails before mutation")
        func selectedControlPlaneIncarnationMismatchFailsClosed() async throws {
            let name = "cluster-selected-token"
            let observed = try snapshot(
                id: name, labels: nodeLabels, incarnation: "current")
            let engine = FakeContainers(get: .success(observed), current: observed)

            try await withScratchKubeconfig(containing: name) { file in
                await #expect(throws: ContainerizationError.self) {
                    try await K8sClusters.delete(
                        name: name,
                        expectedControlPlaneIncarnation: "selected-predecessor",
                        containers: engine,
                        log: log)
                }
                #expect(engine.calls.isEmpty)
                #expect(engine.current?.incarnation == "current")
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(yaml.contains("name: \(name)"))
            }
        }

        @Test("overlapping cluster names never claim another cluster's labeled worker")
        func explicitClusterOwnershipPreventsCrossClusterDelete() async throws {
            let parentName = "foo"
            let nestedName = "foo-worker-1"
            let parent = try snapshot(
                id: parentName,
                labels: [
                    ResourceLabelKeys.plugin: K8sHelper.pluginName,
                    ResourceLabelKeys.cluster: parentName,
                    ResourceLabelKeys.role: K8sHelper.controlPlaneRoleName,
                ],
                incarnation: "parent-token")
            let nested = try snapshot(
                id: nestedName,
                labels: [
                    ResourceLabelKeys.plugin: K8sHelper.pluginName,
                    ResourceLabelKeys.cluster: nestedName,
                    ResourceLabelKeys.role: K8sHelper.controlPlaneRoleName,
                ],
                incarnation: "nested-token")
            let nestedWorker = try snapshot(
                id: "\(nestedName)-worker-1",
                labels: [
                    ResourceLabelKeys.plugin: K8sHelper.pluginName,
                    ResourceLabelKeys.cluster: nestedName,
                    ResourceLabelKeys.role: K8sHelper.workerRoleName,
                ],
                incarnation: "nested-worker-token")
            let engine = FakeContainers(
                controlPlane: parent, workers: [nested, nestedWorker])

            try await withScratchKubeconfig(containing: parentName) { _ in
                try await K8sClusters.delete(
                    name: parentName,
                    expectedControlPlaneIncarnation: "parent-token",
                    containers: engine,
                    log: log)
            }

            #expect(engine.calls.map(\.id) == [parentName, parentName])
            #expect(engine.currentIDs == [nestedName, "\(nestedName)-worker-1"])
        }

        @Test("workers are deleted before the control plane with each observed incarnation")
        func workersAreDeletedFirst() async throws {
            let name = "cluster-workers"
            let controlPlane = try snapshot(
                id: name, labels: nodeLabels, incarnation: "cp-token")
            let workerLabels = [
                "com.apple.container.plugin": "k8s",
                "com.apple.container.resource.role": "worker",
            ]
            let worker1 = try snapshot(
                id: "\(name)-worker-1", labels: workerLabels, incarnation: "w1-token")
            let worker2 = try snapshot(
                id: "\(name)-worker-2", labels: workerLabels, incarnation: "w2-token")
            let engine = FakeContainers(
                controlPlane: controlPlane, workers: [worker2, worker1])

            try await withScratchKubeconfig(containing: name) { _ in
                try await K8sClusters.delete(name: name, containers: engine, log: log)
            }

            #expect(
                engine.calls.map { "\($0.name):\($0.id):\($0.incarnation)" } == [
                    "stop:\(name)-worker-1:w1-token",
                    "delete:\(name)-worker-1:w1-token",
                    "stop:\(name)-worker-2:w2-token",
                    "delete:\(name)-worker-2:w2-token",
                    "stop:\(name):cp-token",
                    "delete:\(name):cp-token",
                ])
            #expect(engine.currentIDs.isEmpty)
        }

        @Test("a real node is stopped and deleted with the node labels required, and its context removed")
        func nodeIsDeletedWithTheRequirementAttached() async throws {
            let name = "cluster-c"
            let node = try snapshot(id: name, labels: nodeLabels)
            let engine = FakeContainers(get: .success(node), current: node)
            try await withScratchKubeconfig(containing: name) { file in
                try await K8sClusters.delete(name: name, containers: engine, log: log)
                let required = K8sClusters.nodeLabels
                #expect(
                    engine.calls == [
                        .init(name: "stop", id: name, labels: required, incarnation: node.incarnation),
                        .init(name: "delete", id: name, labels: required, incarnation: node.incarnation),
                    ])
                #expect(engine.current == nil)
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(!yaml.contains("name: \(name)"))
            }
        }
    }
}
