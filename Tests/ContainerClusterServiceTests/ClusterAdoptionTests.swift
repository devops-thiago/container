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

import ContainerClusterServiceClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerClusterService

/// Clusters made by engines before 1.7.1 have node containers and no record.
@Suite("ClusterService adoption of record-less clusters")
struct ClusterAdoptionTests {
    private func makeRoot() -> FilePath {
        FilePath(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path)
    }

    private func removeRoot(_ root: FilePath) {
        try? FileManager.default.removeItem(atPath: root.string)
    }

    private func makeService(root: FilePath, snapshots: [ContainerSnapshot]) throws -> ClusterService {
        try ClusterService(root: root, listContainers: { snapshots }, log: Logger(label: "test"))
    }

    /// The records on disk, read by a service that sees no containers and so adopts nothing.
    private func storedRecords(_ root: FilePath) async throws -> [ClusterConfiguration] {
        try await makeService(root: root, snapshots: []).list().map(\.configuration)
    }

    /// A node container as an earlier engine made it: only the labels it gave the node.
    private func oldNode(
        _ id: String,
        role: String,
        plugin: String? = "cluster",
        cluster: String? = nil,
        image: String = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95",
        labels: [String: String] = [:],
        domain: String? = nil,
        status: RuntimeStatus = .running,
        created: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) throws -> ContainerSnapshot {
        var snapshot = try makeSnapshot(id: id, role: role, status: status)
        var nodeLabels = labels
        nodeLabels[ResourceLabelKeys.role] = role
        if let plugin { nodeLabels[ResourceLabelKeys.plugin] = plugin }
        if let cluster { nodeLabels[ResourceLabelKeys.cluster] = cluster }
        snapshot.configuration.labels = nodeLabels
        snapshot.configuration.image = ImageDescription(reference: image, descriptor: snapshot.configuration.image.descriptor)
        snapshot.configuration.dns = domain.map { .init(domain: $0) }
        snapshot.configuration.creationDate = created
        return snapshot
    }

    @Test func adoptsSingleNodeClusterOfOurEarlierEngine() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let node = try oldNode(
            "dev", role: "control-plane", cluster: "dev",
            image: "docker.io/kindest/node:v1.34.11@sha256:" + String(repeating: "b", count: 64),
            labels: ["owner": "siliconship"], domain: "test", created: created)
        let service = try makeService(root: root, snapshots: [node])

        let clusters = try await service.list()
        #expect(clusters.map(\.name) == ["dev"])
        let config = try #require(clusters.first).configuration
        // A single node carries both roles, as 1.7.1 labels it.
        #expect(config.nodes == [try NodeConfiguration(name: "dev", roles: ["control-plane", "worker"])])
        #expect(config.kubernetesVersion == "v1.34.11")
        #expect(config.fqdn == "dev.test")
        #expect(config.cni == nil)
        #expect(config.remove == false)
        #expect(config.sharedImageStore == false)
        #expect(config.creationDate == created)
        #expect(config.labels.dictionary == ["owner": "siliconship"])
        #expect(clusters.first?.status.state == .running)

        #expect(try await storedRecords(root) == [config])
        #expect(try await service.get(name: "dev").configuration == config)
    }

    @Test func adoptsMultiNodeClusterOfUpstreamK8sPlugin() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        // Upstream 1.4.0 to 1.6.0: plugin `k8s`, no cluster label, workers found by name.
        let nodes = [
            try oldNode("big-worker-10", role: "worker", plugin: "k8s"),
            try oldNode("big", role: "control-plane", plugin: "k8s"),
            try oldNode("big-worker-2", role: "worker", plugin: "k8s", status: .stopped),
            try oldNode("big-worker-1", role: "worker", plugin: "k8s"),
        ]
        let service = try makeService(root: root, snapshots: nodes)

        let cluster = try #require(try await service.list().first)
        #expect(cluster.configuration.nodes.map(\.name) == ["big", "big-worker-1", "big-worker-2", "big-worker-10"])
        #expect(cluster.configuration.nodes.map(\.roles) == [["control-plane"], ["worker"], ["worker"], ["worker"]])
        #expect(cluster.configuration.kubernetesVersion == "v1.35.5")
        #expect(cluster.configuration.fqdn == nil)
        #expect(cluster.configuration.labels.dictionary.isEmpty)
        #expect(cluster.status.state == .degraded)
        #expect(try await storedRecords(root).map(\.name) == ["big"])
    }

    @Test func adoptsOnGetToo() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(
            root: root,
            snapshots: [
                try oldNode("dev", role: "control-plane", cluster: "dev"),
                try oldNode("dev-worker-1", role: "worker", cluster: "dev"),
            ])
        let cluster = try await service.get(name: "dev")
        #expect(cluster.configuration.nodes.map(\.name) == ["dev", "dev-worker-1"])
        #expect(cluster.configuration.nodes[0].roles == ["control-plane"])
        #expect(try await storedRecords(root).map(\.name) == ["dev"])
    }

    @Test func secondListAddsNothing() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(
            root: root,
            snapshots: [
                try oldNode("dev", role: "control-plane", cluster: "dev"),
                try oldNode("dev-worker-1", role: "worker", cluster: "dev"),
                try oldNode("other", role: "control-plane", cluster: "other"),
            ])
        let first = try await service.list()
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.string).sorted()
        let second = try await service.list()
        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.string).sorted() == entries)
        // A new service over the same records adopts nothing more either.
        let restarted = try await makeService(
            root: root,
            snapshots: [
                try oldNode("dev", role: "control-plane", cluster: "dev"),
                try oldNode("dev-worker-1", role: "worker", cluster: "dev"),
                try oldNode("other", role: "control-plane", cluster: "other"),
            ]
        ).list()
        #expect(restarted == first)
        #expect(try await storedRecords(root).map(\.name) == ["dev", "other"])
    }

    @Test func ignoresContainersThatAreNotClusterNodes() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(
            root: root,
            snapshots: [
                try oldNode("vm", role: "control-plane", plugin: "machine"),
                try oldNode("web", role: "control-plane", plugin: nil),
                try oldNode("builder", role: "builder", plugin: nil),
                try oldNode("dev", role: "control-plane", plugin: "cluster2", cluster: "dev"),
            ])
        #expect(try await service.list().isEmpty)
        #expect(try await storedRecords(root).isEmpty)
        for name in ["vm", "web", "dev"] {
            do {
                _ = try await service.get(name: name)
                Issue.record("expected \(name) not found")
            } catch let error as ContainerizationError {
                #expect(error.code == .notFound)
            }
        }
    }

    @Test func leavesClusterBeingCreatedAlone() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        // `cluster create` records the cluster before making its nodes: mid-create, the record
        // lists every node while only some exist.
        let service = try makeService(
            root: root,
            snapshots: [try oldNode("dev", role: "control-plane", cluster: "dev")])
        let config = makeConfig("dev", workers: 2)
        _ = try await service.create(configuration: config)
        let clusters = try await service.list()
        #expect(clusters.map(\.configuration) == [config])
        #expect(try await storedRecords(root) == [config])
    }

    private actor ServiceBox {
        private var service: ClusterService?

        func set(_ service: ClusterService) {
            self.service = service
        }

        func create(_ configuration: ClusterConfiguration) async throws {
            _ = try await service?.create(configuration: configuration)
        }

        func delete(_ name: String) async {
            try? await service?.delete(name: name)
        }
    }

    @Test func keepsRecordCreatedWhileContainersWereListed() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let box = ServiceBox()
        let config = makeConfig("dev", workers: 2)
        let nodes = [
            try oldNode("dev", role: "control-plane", cluster: "dev"),
            try oldNode("dev-worker-1", role: "worker", cluster: "dev"),
        ]
        let service = try ClusterService(
            root: root,
            listContainers: {
                // A create lands while the listing is in flight, and the listing already sees
                // its first nodes.
                try await box.create(config)
                return nodes
            }, log: Logger(label: "test"))
        await box.set(service)
        let clusters = try await service.list()
        #expect(clusters.map(\.configuration) == [config])
        #expect(try await storedRecords(root) == [config])
    }

    @Test func doesNotAdoptClusterDeletedWhileContainersWereListed() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let box = ServiceBox()
        let nodes = [try oldNode("dev", role: "control-plane", cluster: "dev")]
        let service = try ClusterService(
            root: root,
            listContainers: {
                // `cluster delete` removed the nodes after this listing saw them, then asked the
                // service to drop a record the cluster never had.
                await box.delete("dev")
                return nodes
            }, log: Logger(label: "test"))
        await box.set(service)
        #expect(try await service.list().isEmpty)
        #expect(try await storedRecords(root).isEmpty)
    }

    @Test func skipsWorkersWithoutTheirControlPlane() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(
            root: root,
            snapshots: [
                try oldNode("gone-worker-1", role: "worker", cluster: "gone"),
                try oldNode("gone-worker-2", role: "worker", plugin: "k8s"),
                try oldNode("kept", role: "control-plane", cluster: "kept"),
            ])
        #expect(try await service.list().map(\.name) == ["kept"])
        #expect(try await storedRecords(root).map(\.name) == ["kept"])
        do {
            _ = try await service.get(name: "gone")
            Issue.record("expected gone not found")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
        }
    }

    @Test func createRefusesNameOfAdoptedCluster() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let service = try makeService(root: root, snapshots: [try oldNode("dev", role: "control-plane", cluster: "dev")])
        // `K8sClusters.create` looks the name up first, which adopts the old cluster.
        let adopted = try await service.get(name: "dev").configuration
        do {
            _ = try await service.create(configuration: makeConfig("dev", workers: 1))
            Issue.record("expected exists")
        } catch let error as ContainerizationError {
            #expect(error.code == .exists)
        }
        #expect(try await storedRecords(root) == [adopted])
    }

    @Test func untaggedNodeImageTakesTheEarlierDefaultVersion() async throws {
        let root = makeRoot()
        defer { removeRoot(root) }
        let node = try oldNode(
            "dev", role: "control-plane", cluster: "dev",
            image: "docker.io/kindest/node@sha256:" + String(repeating: "c", count: 64))
        let service = try makeService(root: root, snapshots: [node])
        #expect(try await service.list().first?.configuration.kubernetesVersion == RecordlessClusters.defaultKubernetesVersion)
    }

    @Test func qualifiedNameIsItsOwnFQDN() throws {
        let node = try oldNode("dev.example", role: "control-plane", cluster: "dev.example", domain: "test")
        #expect(RecordlessClusters.fqdn(name: "dev.example", controlPlane: node) == "dev.example")
        let plain = try oldNode("dev", role: "control-plane", cluster: "dev", domain: "")
        #expect(RecordlessClusters.fqdn(name: "dev", controlPlane: plain) == nil)
    }
}
