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

@testable import ContainerCluster

private func snapshot(id: String, labels: [String: String]) throws -> ContainerSnapshot {
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
            "incarnation": "incarnation-\(id)",
            "status": "running",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func node(id: String, cluster: String, role: String) throws -> ContainerSnapshot {
    try snapshot(
        id: id,
        labels: [
            ResourceLabelKeys.plugin: ClusterHelper.pluginName,
            ResourceLabelKeys.cluster: cluster,
            ResourceLabelKeys.role: role,
        ])
}

private func configuration(_ name: String, workers: UInt = 0) throws -> ClusterConfiguration {
    try ClusterConfiguration.make(
        name: name, nodeImage: "docker.io/kindest/node:v1.35.5", remove: false, workers: workers, cni: nil, fqdn: nil)
}

/// Stands in for the cluster service's records. As the service does, `create` refuses a name
/// already recorded, and `get` and `delete` fail `.notFound` for one that is not.
final class FakeClusterRecords: K8sClusterRecords, Sendable {
    private let stored: Mutex<[String: ClusterConfiguration]>

    init(_ configurations: [ClusterConfiguration] = []) {
        stored = Mutex(Dictionary(uniqueKeysWithValues: configurations.map { ($0.name, $0) }))
    }

    var all: [ClusterConfiguration] { stored.withLock { $0.values.sorted { $0.name < $1.name } } }

    /// Another create's record taking the name's place, as the service allows while the
    /// record there has no live node.
    func replace(with configuration: ClusterConfiguration) {
        stored.withLock { $0[configuration.name] = configuration }
    }

    func create(configuration: ClusterConfiguration) async throws -> ClusterResource {
        try stored.withLock { stored in
            guard stored[configuration.name] == nil else {
                throw ContainerizationError(.exists, message: "cluster \(configuration.name) already exists")
            }
            stored[configuration.name] = configuration
        }
        return resource(configuration)
    }

    func get(name: String) async throws -> ClusterResource {
        guard let configuration = stored.withLock({ $0[name] }) else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        return resource(configuration)
    }

    func delete(name: String) async throws {
        try stored.withLock { stored in
            guard stored.removeValue(forKey: name) != nil else {
                throw ContainerizationError(.notFound, message: "cluster \(name) not found")
            }
        }
    }

    private func resource(_ configuration: ClusterConfiguration) -> ClusterResource {
        let nodes = configuration.nodes.map { ClusterNodeState(name: $0.name, status: .stopped) }
        return ClusterResource(configuration: configuration, status: ClusterStatus(state: .stopped, nodes: nodes))
    }
}

/// The engine as a create sees it before it makes any node: the containers that exist, by ID.
/// The listing carries only this plugin's nodes, as the filtered one does.
private final class FakeEngine: K8sClusterContainers, Sendable {
    private let containers: Mutex<[String: ContainerSnapshot]>

    init(_ containers: [ContainerSnapshot] = []) {
        self.containers = Mutex(Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) }))
    }

    var ids: Set<String> { containers.withLock { Set($0.keys) } }

    func add(_ container: ContainerSnapshot) {
        containers.withLock { $0[container.id] = container }
    }

    func get(id: String) async throws -> ContainerSnapshot {
        guard let container = containers.withLock({ $0[id] }) else {
            throw ContainerizationError(.notFound, message: "container with ID \(id) not found")
        }
        return container
    }

    func listNodes() async throws -> [ContainerSnapshot] {
        containers.withLock { $0.values.filter { ClusterHelper.ownsNode($0.configuration.labels) } }
    }

    func stop(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {
        Issue.record("a create stops no container it did not make")
    }

    func delete(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {
        Issue.record("a create deletes no container it did not make")
    }
}

/// The record a create writes before provisioning, and what becomes of it when the create fails.
@Suite("K8sClusters.create record")
struct K8sCreateRecordTests {
    /// Runs the create's record-and-provision step and returns the error it threw, if any,
    /// and whether provisioning was reached.
    private func create(
        _ configuration: ClusterConfiguration,
        engine: FakeEngine,
        records: FakeClusterRecords,
        provision: @Sendable () async throws -> Void = {}
    ) async -> (error: ContainerizationError?, provisioned: Bool) {
        let provisioned = Mutex(false)
        do {
            try await K8sClusters.recordAndProvision(configuration: configuration, containers: engine, records: records) {
                provisioned.withLock { $0 = true }
                try await provision()
            }
            return (nil, provisioned.withLock { $0 })
        } catch {
            return (error as? ContainerizationError, provisioned.withLock { $0 })
        }
    }

    @Test("a create that provisions leaves its record")
    func successKeepsTheRecord() async throws {
        let config = try configuration("dev", workers: 1)
        let records = FakeClusterRecords()
        let result = await create(config, engine: FakeEngine(), records: records)
        #expect(result.error == nil)
        #expect(result.provisioned)
        #expect(records.all == [config])
    }

    @Test("an ordinary container holding the control plane's name leaves no record")
    func ordinaryContainerAtControlPlaneName() async throws {
        let engine = FakeEngine([try snapshot(id: "web", labels: ["app": "web"])])
        let records = FakeClusterRecords()
        let result = await create(try configuration("web"), engine: engine, records: records)
        #expect(result.error?.code == .exists)
        #expect(!result.provisioned, "the collision is found before any node is made")
        #expect(records.all.isEmpty)
        #expect(engine.ids == ["web"], "the container is untouched")
    }

    @Test("an ordinary container holding a worker's name leaves no record")
    func ordinaryContainerAtWorkerName() async throws {
        let engine = FakeEngine([try snapshot(id: "dev-worker-2", labels: ["app": "web"])])
        let records = FakeClusterRecords()
        let result = await create(try configuration("dev", workers: 2), engine: engine, records: records)
        #expect(result.error?.code == .exists)
        #expect(!result.provisioned)
        #expect(records.all.isEmpty)
    }

    @Test("another cluster's node holding the name leaves no record, and that cluster's stays")
    func nodeOfAnotherClusterAtTheName() async throws {
        let other = try configuration("foo", workers: 1)
        let engine = FakeEngine([
            try node(id: "foo", cluster: "foo", role: ClusterHelper.controlPlaneRoleName),
            try node(id: "foo-worker-1", cluster: "foo", role: ClusterHelper.workerRoleName),
        ])
        let records = FakeClusterRecords([other])
        let result = await create(try configuration("foo-worker-1"), engine: engine, records: records)
        #expect(result.error?.code == .exists)
        #expect(!result.provisioned)
        #expect(records.all == [other])
    }

    @Test("a node of the same cluster is refused by the record, which is kept")
    func liveClusterIsRefusedByItsRecord() async throws {
        let live = try configuration("dev")
        let engine = FakeEngine([try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName)])
        let records = FakeClusterRecords([live])
        let result = await create(try configuration("dev", workers: 1), engine: engine, records: records)
        #expect(result.error?.code == .exists)
        #expect(!result.provisioned)
        #expect(records.all == [live])
    }

    @Test("losing a race to another create of the same cluster leaves the winner's record")
    func concurrentCreateKeepsTheWinnersRecord() async throws {
        let engine = FakeEngine()
        let records = FakeClusterRecords()
        let winner = try configuration("dev", workers: 1)
        // Both creates recorded the name before either made a node. The other's record
        // replaced this one's, its control plane took the name, and this one's fails on it.
        let result = await create(try configuration("dev"), engine: engine, records: records) {
            records.replace(with: winner)
            engine.add(try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName))
            throw ContainerizationError(.exists, message: "container with ID dev already exists")
        }
        #expect(result.error?.code == .exists)
        #expect(result.provisioned)
        #expect(records.all == [winner])
    }

    @Test("a create whose own record still stands when it loses the race keeps it for the winner")
    func concurrentCreateKeepsTheOnlyRecord() async throws {
        let engine = FakeEngine()
        let records = FakeClusterRecords()
        let config = try configuration("dev")
        // The other create wrote its record first and this one replaced it, so the record
        // that describes the winner's nodes is the one this create wrote.
        let result = await create(config, engine: engine, records: records) {
            engine.add(try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName))
            throw ContainerizationError(.exists, message: "container with ID dev already exists")
        }
        #expect(result.error?.code == .exists)
        #expect(records.all == [config])
    }

    @Test("a provisioning failure other than exists removes the record")
    func provisioningFailureRemovesTheRecord() async throws {
        let records = FakeClusterRecords()
        let result = await create(try configuration("dev"), engine: FakeEngine(), records: records) {
            throw ContainerizationError(.internalError, message: "kubeadm init failed")
        }
        #expect(result.error?.code == .internalError)
        #expect(records.all.isEmpty)
    }
}
