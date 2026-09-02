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

private func snapshot(id: String, labels: [String: String]) throws -> ContainerSnapshot {
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
            "status": "running",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private let nodeLabels = ["com.apple.container.plugin": "k8s", "com.apple.container.resource.role": "control-plane"]
private let ordinaryLabels = ["app": "web"]

/// Stands in for the engine. `current` is what the ID names *now*; stop and delete refuse,
/// as the service does, when it no longer carries the labels the caller requires.
private final class FakeContainers: K8sClusterContainers, @unchecked Sendable {
    struct Call: Equatable { let name: String; let labels: [String: String] }

    private let state: Mutex<(getResult: Result<ContainerSnapshot, Error>, current: ContainerSnapshot?, calls: [Call])>

    init(get: Result<ContainerSnapshot, Error>, current: ContainerSnapshot?) {
        state = Mutex((get, current, []))
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var current: ContainerSnapshot? { state.withLock { $0.current } }

    /// The race under test: between the caller's lookup and its mutation, the ID comes to
    /// name something else.
    func replace(with replacement: ContainerSnapshot) { state.withLock { $0.current = replacement } }

    func get(id: String) async throws -> ContainerSnapshot {
        try state.withLock { try $0.getResult.get() }
    }

    func stop(id: String, requiredLabels: [String: String]) async throws {
        try mutate("stop", id: id, requiredLabels: requiredLabels) { _ in }
    }

    func delete(id: String, requiredLabels: [String: String]) async throws {
        try mutate("delete", id: id, requiredLabels: requiredLabels) { $0 = nil }
    }

    private func mutate(_ name: String, id: String, requiredLabels: [String: String], _ apply: (inout ContainerSnapshot?) -> Void) throws {
        try state.withLock { s in
            guard let current = s.current else {
                throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
            }
            guard requiredLabels.allSatisfy({ current.configuration.labels[$0.key] == $0.value }) else {
                throw ContainerizationError(.invalidArgument, message: "container \(id) does not carry the labels this operation requires")
            }
            s.calls.append(Call(name: name, labels: requiredLabels))
            apply(&s.current)
        }
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

        @Test("a real node is stopped and deleted with the node labels required, and its context removed")
        func nodeIsDeletedWithTheRequirementAttached() async throws {
            let name = "cluster-c"
            let node = try snapshot(id: name, labels: nodeLabels)
            let engine = FakeContainers(get: .success(node), current: node)
            try await withScratchKubeconfig(containing: name) { file in
                try await K8sClusters.delete(name: name, containers: engine, log: log)
                let required = K8sClusters.nodeLabels
                #expect(engine.calls == [.init(name: "stop", labels: required), .init(name: "delete", labels: required)])
                #expect(engine.current == nil)
                let yaml = try String(contentsOf: file, encoding: .utf8)
                #expect(!yaml.contains("name: \(name)"))
            }
        }
    }
}
