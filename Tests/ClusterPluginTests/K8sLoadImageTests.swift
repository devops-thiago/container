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
    labels: [String: String],
    status: String = "running"
) throws -> ContainerSnapshot {
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
            "incarnation": "\(id)-incarnation",
            "status": "\(status)",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func node(id: String, cluster: String, role: String, status: String = "running") throws -> ContainerSnapshot {
    try snapshot(
        id: id,
        labels: [
            ResourceLabelKeys.plugin: K8sHelper.pluginName,
            ResourceLabelKeys.cluster: cluster,
            ResourceLabelKeys.role: role,
        ],
        status: status)
}

private func controlPlane(_ cluster: String, status: String = "running") throws -> ContainerSnapshot {
    try node(id: cluster, cluster: cluster, role: K8sHelper.controlPlaneRoleName, status: status)
}

private func worker(_ cluster: String, _ number: Int, status: String = "running") throws -> ContainerSnapshot {
    try node(id: "\(cluster)-worker-\(number)", cluster: cluster, role: K8sHelper.workerRoleName, status: status)
}

/// The engine as a load sees it: the containers by ID, a listing, and ctr runs that record
/// what they were asked to do and fail for the nodes a test names.
private final class FakeNodes: K8sNodeImageLoader, @unchecked Sendable {
    enum Call: Equatable {
        case importImage(node: String, archive: String)
        case tag(node: String, source: String, target: String)
    }

    private struct State {
        var calls: [Call] = []
        var inFlight = 0
        var maximumInFlight = 0
    }

    private let containers: [String: ContainerSnapshot]
    private let listed: [ContainerSnapshot]
    private let failingImports: Set<String>
    private let failingTags: Set<String>
    private let state = Mutex(State())

    init(
        _ listed: [ContainerSnapshot],
        others: [ContainerSnapshot] = [],
        failingImports: Set<String> = [],
        failingTags: Set<String> = []
    ) {
        self.listed = listed
        self.containers = Dictionary(uniqueKeysWithValues: (listed + others).map { ($0.id, $0) })
        self.failingImports = failingImports
        self.failingTags = failingTags
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var imported: [String] {
        calls.compactMap {
            if case .importImage(let node, _) = $0 { return node }
            return nil
        }
    }
    var maximumInFlight: Int { state.withLock { $0.maximumInFlight } }

    func get(id: String) async throws -> ContainerSnapshot {
        guard let container = containers[id] else {
            throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
        }
        return container
    }

    func listNodes() async throws -> [ContainerSnapshot] { listed }

    func importImage(nodeID: String, archivePath: String) async throws {
        state.withLock { state in
            state.calls.append(.importImage(node: nodeID, archive: archivePath))
            state.inFlight += 1
            state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
        }
        // Give the other imports a chance to overlap this one.
        for _ in 0..<5 { await Task.yield() }
        state.withLock { $0.inFlight -= 1 }
        if failingImports.contains(nodeID) {
            throw ContainerizationError(.internalError, message: "ctr import exited 1 on \(nodeID): no space left on device")
        }
    }

    func tagImage(nodeID: String, source: String, target: String) async throws {
        state.withLock { $0.calls.append(.tag(node: nodeID, source: source, target: target)) }
        if failingTags.contains(nodeID) {
            throw ContainerizationError(.internalError, message: "ctr tag exited 1 on \(nodeID)")
        }
    }
}

@Suite("k8s load-image")
struct K8sLoadImageTests {
    private let log = Logger(label: "k8s-load-image-tests")
    private let archive = "/tmp/archive.tar"

    // MARK: - Which nodes

    @Test("every node of the named cluster is chosen, the control plane first and then the workers by ID")
    func everyNodeOfTheCluster() async throws {
        let engine = FakeNodes([
            try worker("dev", 2), try controlPlane("other"), try worker("other", 1),
            try controlPlane("dev"), try worker("dev", 1),
        ])

        let nodes = try await K8sClusters.nodesToLoad(cluster: "dev", containers: engine)

        #expect(nodes.map(\.id) == ["dev", "dev-worker-1", "dev-worker-2"])
    }

    @Test("a stopped node is still chosen, so it can be reported")
    func stoppedNodesAreChosen() async throws {
        let engine = FakeNodes([try controlPlane("dev"), try worker("dev", 1, status: "stopped")])

        let nodes = try await K8sClusters.nodesToLoad(cluster: "dev", containers: engine)

        #expect(nodes.map(\.id) == ["dev", "dev-worker-1"])
    }

    @Test("a nested cluster's workers belong to it, not to the cluster whose name prefixes it")
    func nestedClusterWorkersAreNotClaimed() throws {
        let listed = [
            try controlPlane("dev"), try worker("dev", 1),
            try controlPlane("dev-worker-1-x"), try worker("dev-worker-1-x", 1),
        ]

        #expect(K8sClusters.clusterNodes(cluster: "dev", listed: listed).map(\.id) == ["dev", "dev-worker-1"])
        #expect(
            K8sClusters.clusterNodes(cluster: "dev-worker-1-x", listed: listed).map(\.id)
                == ["dev-worker-1-x", "dev-worker-1-x-worker-1"])
    }

    @Test("a name no container has is not a cluster")
    func unknownClusterIsRefused() async throws {
        let engine = FakeNodes([try controlPlane("other")])

        let error = await #expect(throws: ContainerizationError.self) {
            try await K8sClusters.nodesToLoad(cluster: "dev", containers: engine)
        }
        #expect(error?.code == .notFound)
    }

    @Test("a container this plugin does not own is refused")
    func ordinaryContainerIsRefused() async throws {
        let engine = FakeNodes([], others: [try snapshot(id: "web", labels: ["app": "web"])])

        let error = await #expect(throws: ContainerizationError.self) {
            try await K8sClusters.nodesToLoad(cluster: "web", containers: engine)
        }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message == "web is not a k8s cluster")
    }

    @Test("a worker's ID is not a cluster name")
    func workerIDIsNotACluster() async throws {
        let engine = FakeNodes([try controlPlane("dev"), try worker("dev", 1)])

        let error = await #expect(throws: ContainerizationError.self) {
            try await K8sClusters.nodesToLoad(cluster: "dev-worker-1", containers: engine)
        }
        #expect(error?.code == .notFound)
    }

    // MARK: - Fan-out

    @Test("a single-node cluster imports and tags once, as before workers existed")
    func singleNodeCluster() async throws {
        let cp = try controlPlane("dev")
        let engine = FakeNodes([cp])

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: [cp], containers: engine, log: log)

        #expect(results == [.init(node: "dev", role: K8sHelper.controlPlaneRoleName, outcome: .loaded)])
        #expect(
            engine.calls == [
                .importImage(node: "dev", archive: archive),
                .tag(node: "dev", source: "docker.io/library/my-app:latest", target: "docker.io/my-app:latest"),
            ])
        #expect(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results) == nil)
    }

    @Test("every node of a cluster with workers gets the image and the tag the user gave")
    func everyNodeIsLoaded() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1), try worker("dev", 2)]
        let engine = FakeNodes(nodes)

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: nodes, containers: engine, log: log)

        #expect(results.map(\.node) == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(results.allSatisfy { $0.succeeded })
        #expect(Set(engine.imported) == ["dev", "dev-worker-1", "dev-worker-2"])
        for id in ["dev", "dev-worker-1", "dev-worker-2"] {
            #expect(engine.calls.contains(.tag(node: id, source: "docker.io/library/my-app:latest", target: "docker.io/my-app:latest")))
        }
        #expect(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results) == nil)
    }

    @Test("a reference that is already normalized is imported without a tag")
    func normalizedReferenceIsNotTagged() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1)]
        let engine = FakeNodes(nodes)

        let results = await K8sClusters.importArchive(
            archive, image: "registry.example.com/team/app:1.0", into: nodes, containers: engine, log: log)

        #expect(results.allSatisfy { $0.succeeded })
        #expect(Set(engine.imported) == ["dev", "dev-worker-1"])
        #expect(engine.calls.count == 2, "no tag calls")
    }

    @Test("a node whose import fails does not hide the others, and the error names only it")
    func oneFailedImportDoesNotHideTheOthers() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1), try worker("dev", 2)]
        let engine = FakeNodes(nodes, failingImports: ["dev-worker-1"])

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: nodes, containers: engine, log: log)

        #expect(
            results.map(\.outcome) == [
                .loaded,
                .failed("ctr import exited 1 on dev-worker-1: no space left on device"),
                .loaded,
            ])
        #expect(Set(engine.imported) == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(!engine.calls.contains { $0 == .tag(node: "dev-worker-1", source: "docker.io/library/my-app:latest", target: "docker.io/my-app:latest") })

        let error = try #require(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results))
        #expect(error.code == .internalError)
        #expect(
            error.message
                == "image docker.io/my-app:latest was not loaded into 1 of 3 nodes of cluster dev: "
                + "dev-worker-1: ctr import exited 1 on dev-worker-1: no space left on device")
    }

    @Test("a node whose tag fails is reported as failed")
    func failedTagIsAFailure() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1)]
        let engine = FakeNodes(nodes, failingTags: ["dev"])

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: nodes, containers: engine, log: log)

        #expect(results.map(\.outcome) == [.failed("ctr tag exited 1 on dev"), .loaded])
        #expect(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results) != nil)
    }

    @Test("a stopped node is reported without an attempt, and the running nodes still load")
    func stoppedNodeIsReported() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1, status: "stopped"), try worker("dev", 2)]
        let engine = FakeNodes(nodes)

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: nodes, containers: engine, log: log)

        #expect(results.map(\.outcome) == [.loaded, .notRunning("stopped"), .loaded])
        #expect(Set(engine.imported) == ["dev", "dev-worker-2"])
        #expect(
            !engine.calls.contains { call in
                switch call {
                case .importImage(let node, _), .tag(let node, _, _): node == "dev-worker-1"
                }
            })

        let error = try #require(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results))
        #expect(error.code == .invalidState)
        #expect(error.message.contains("dev-worker-1 is not running (stopped)"))
        #expect(error.message.contains("1 of 3 nodes"))
    }

    @Test("every node that missed the image is named in the one error")
    func everyMissedNodeIsNamed() async throws {
        let nodes = [try controlPlane("dev"), try worker("dev", 1, status: "stopped"), try worker("dev", 2)]
        let engine = FakeNodes(nodes, failingImports: ["dev-worker-2"])

        let results = await K8sClusters.importArchive(
            archive, image: "docker.io/my-app:latest", into: nodes, containers: engine, log: log)

        let error = try #require(K8sClusters.imageLoadFailure(image: "docker.io/my-app:latest", cluster: "dev", results: results))
        #expect(error.code == .internalError)
        #expect(error.message.contains("2 of 3 nodes"))
        #expect(error.message.contains("dev-worker-1 is not running (stopped)"))
        #expect(error.message.contains("dev-worker-2: ctr import exited 1"))
    }

    @Test("imports run a bounded number at a time and still reach every node, results in node order")
    func importsAreBounded() async throws {
        let nodes = [try controlPlane("dev")] + (try (1...7).map { try worker("dev", $0) })
        let engine = FakeNodes(nodes)

        let results = await K8sClusters.importArchive(
            archive, image: "registry.example.com/app:1", into: nodes, containers: engine,
            maximumConcurrent: 3, log: log)

        #expect(results.map(\.node) == nodes.map(\.id))
        #expect(results.allSatisfy { $0.succeeded })
        #expect(engine.imported.count == nodes.count)
        #expect(Set(engine.imported) == Set(nodes.map(\.id)))
        #expect(engine.maximumInFlight <= 3)
    }
}
