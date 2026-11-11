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
import SystemPackage
import Testing

@testable import ContainerCluster

private func node(id: String, cluster: String, role: String) throws -> ContainerSnapshot {
    let labels = [
        ResourceLabelKeys.plugin: ClusterHelper.pluginName,
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
            "incarnation": "incarnation-\(id)",
            "status": "running",
            "networks": []
        }
        """
    return try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
}

private func configuration(_ name: String, workers: UInt = 0) throws -> ClusterConfiguration {
    try ClusterConfiguration.make(
        name: name, nodeImage: "docker.io/kindest/node:v1.35.5", remove: false, workers: workers, cni: nil, fqdn: nil)
}

/// An engine whose nodes a create adds and a delete removes.
private final class Engine: K8sClusterContainers, Sendable {
    private let containers = Mutex<[String: ContainerSnapshot]>([:])

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

    func stop(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {}

    func delete(id: String, requiredLabels: [String: String], expectedIncarnation: String) async throws {
        containers.withLock { _ = $0.removeValue(forKey: id) }
    }
}

/// The cluster service's records with its replacement rule: a create takes the place of a
/// record none of whose nodes exist, and is refused `.exists` by one with a live node.
private final class Records: K8sClusterRecords, Sendable {
    private let stored = Mutex<[String: ClusterConfiguration]>([:])
    private let engine: Engine

    init(engine: Engine) { self.engine = engine }

    var all: [ClusterConfiguration] { stored.withLock { $0.values.sorted { $0.name < $1.name } } }

    func create(configuration: ClusterConfiguration) async throws -> ClusterResource {
        let live = engine.ids
        try stored.withLock { stored in
            if let existing = stored[configuration.name], existing.nodes.contains(where: { live.contains($0.name) }) {
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

/// Holds an operation at a chosen point until the test lets it go on.
private final class Checkpoint: Sendable {
    private let reached: AsyncStream<Void>
    private let reach: AsyncStream<Void>.Continuation
    private let resumed: AsyncStream<Void>
    private let resume: AsyncStream<Void>.Continuation

    init() {
        (reached, reach) = AsyncStream.makeStream()
        (resumed, resume) = AsyncStream.makeStream()
    }

    /// Called by the operation: report arrival, then wait to be released.
    func pause() async {
        reach.yield()
        for await _ in resumed { return }
    }

    /// Called by the test: wait until the operation has arrived.
    func arrival() async {
        for await _ in reached { return }
    }

    func release() { resume.yield() }
}

/// A fresh directory for one test's lock files, removed when the test ends.
private struct LockDirectory {
    let path: FilePath
    private let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func code(_ operation: () async throws -> Void) async -> ContainerizationError.Code? {
    do {
        try await operation()
        return nil
    } catch {
        return (error as? ContainerizationError)?.code
    }
}

/// One create or delete of a cluster name at a time, in this process and across processes.
@Suite("Cluster operation lock")
struct ClusterOperationLockTests {
    private let log = Logger(label: "ClusterOperationLockTests")

    private func create(
        _ configuration: ClusterConfiguration, engine: Engine, records: Records, locks: LockDirectory,
        provision: @Sendable () async throws -> Void
    ) async throws {
        try await K8sClusters.exclusively(name: configuration.name, locks: locks.path) {
            try await K8sClusters.recordAndProvision(
                configuration: configuration, containers: engine, records: records, provision: provision)
        }
    }

    private func delete(_ name: String, engine: Engine, records: Records, locks: LockDirectory) async throws {
        try await K8sClusters.exclusively(name: name, locks: locks.path) {
            try await K8sClusters.delete(name: name, containers: engine, records: records, log: log)
        }
    }

    @Test("a held name refuses a second hold, another name does not, and a release frees it")
    func secondHoldIsRefused() throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let first = try ClusterOperationLock.acquire(name: "dev", in: locks.path)
        #expect {
            _ = try ClusterOperationLock.acquire(name: "dev", in: locks.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.code == .invalidState && error.message.contains("cluster dev is being created or deleted")
        }
        let other = try ClusterOperationLock.acquire(name: "prod", in: locks.path)
        other.release()
        first.release()
        first.release()
        try ClusterOperationLock.acquire(name: "dev", in: locks.path).release()
    }

    @Test("a hold that goes out of scope frees the name")
    func droppedHoldFreesTheName() throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        do { _ = try ClusterOperationLock.acquire(name: "dev", in: locks.path) }
        try ClusterOperationLock.acquire(name: "dev", in: locks.path).release()
    }

    @Test("a name that is not a container ID is refused before any file is made")
    func invalidNameIsRefused() throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        #expect {
            _ = try ClusterOperationLock.acquire(name: "../escape", in: locks.path)
        } throws: { ($0 as? ContainerizationError)?.code == .invalidArgument }
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path.string).isEmpty)
    }

    @Test("an operation that throws frees the name")
    func failedOperationFreesTheName() async throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let thrown = await code {
            try await K8sClusters.exclusively(name: "dev", locks: locks.path) {
                throw ContainerizationError(.internalError, message: "kubeadm init failed")
            }
        }
        #expect(thrown == .internalError)
        try ClusterOperationLock.acquire(name: "dev", in: locks.path).release()
    }

    @Test("a second create cannot replace the record of one still provisioning, whose failure then removes only its own")
    func failedCreateRemovesOnlyItsOwnRecord() async throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let engine = Engine()
        let records = Records(engine: engine)
        let first = try configuration("dev")
        let second = try configuration("dev", workers: 1)
        let provisioning = Checkpoint()

        let firstCreate = Task {
            await code {
                try await create(first, engine: engine, records: records, locks: locks) {
                    await provisioning.pause()
                    throw ContainerizationError(.internalError, message: "kubeadm init failed")
                }
            }
        }
        await provisioning.arrival()

        // No node of the first exists yet, so the service alone would let this one replace
        // the record, and the first's failure would then remove the replacement.
        let secondProvisioned = Mutex(false)
        let refused = await code {
            try await create(second, engine: engine, records: records, locks: locks) {
                secondProvisioned.withLock { $0 = true }
            }
        }
        #expect(refused == .invalidState)
        #expect(!secondProvisioned.withLock { $0 })
        #expect(records.all == [first])

        provisioning.release()
        #expect(await firstCreate.value == .internalError)
        #expect(records.all.isEmpty)

        // The name is free again: the second create now records and provisions.
        try await create(second, engine: engine, records: records, locks: locks) {
            engine.add(try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName))
        }
        #expect(records.all == [second])
    }

    @Test("a delete cannot remove the record of a create that has made no node yet")
    func deleteWaitsOutACreateWithNoNode() async throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let engine = Engine()
        let records = Records(engine: engine)
        let config = try configuration("dev")
        let provisioning = Checkpoint()

        let creating = Task {
            await code {
                try await create(config, engine: engine, records: records, locks: locks) {
                    await provisioning.pause()
                    engine.add(try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName))
                }
            }
        }
        await provisioning.arrival()

        let refused = await code { try await delete("dev", engine: engine, records: records, locks: locks) }
        #expect(refused == .invalidState)
        #expect(records.all == [config])

        provisioning.release()
        #expect(await creating.value == nil)
        #expect(engine.ids == ["dev"])
        #expect(records.all == [config])
    }

    @Test("a delete cannot run between a create's nodes, and afterwards removes every one")
    func deleteCannotSplitACreate() async throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let engine = Engine()
        let records = Records(engine: engine)
        let config = try configuration("dev", workers: 1)
        let worker = ClusterHelper.workerName(cluster: "dev", index: 1)
        let betweenNodes = Checkpoint()

        let creating = Task {
            await code {
                try await create(config, engine: engine, records: records, locks: locks) {
                    engine.add(try node(id: "dev", cluster: "dev", role: ClusterHelper.controlPlaneRoleName))
                    await betweenNodes.pause()
                    engine.add(try node(id: worker, cluster: "dev", role: ClusterHelper.workerRoleName))
                }
            }
        }
        await betweenNodes.arrival()

        // The control plane is up and the worker is not: a delete now would list one node,
        // remove it and the record, and leave the worker the create makes next.
        let refused = await code { try await delete("dev", engine: engine, records: records, locks: locks) }
        #expect(refused == .invalidState)
        #expect(engine.ids == ["dev"])
        #expect(records.all == [config])

        betweenNodes.release()
        #expect(await creating.value == nil)
        #expect(engine.ids == ["dev", worker])

        try await delete("dev", engine: engine, records: records, locks: locks)
        #expect(engine.ids.isEmpty)
        #expect(records.all.isEmpty)
    }

    @Test("a create cannot start while a delete of the name is removing its nodes")
    func createWaitsOutADelete() async throws {
        let locks = try LockDirectory()
        defer { locks.remove() }
        let engine = Engine()
        let records = Records(engine: engine)
        let config = try configuration("dev")
        let deleting = Checkpoint()

        let held = Task {
            await code {
                try await K8sClusters.exclusively(name: "dev", locks: locks.path) { await deleting.pause() }
            }
        }
        await deleting.arrival()

        let refused = await code {
            try await create(config, engine: engine, records: records, locks: locks) {}
        }
        #expect(refused == .invalidState)
        #expect(records.all.isEmpty)

        deleting.release()
        #expect(await held.value == nil)
        try await create(config, engine: engine, records: records, locks: locks) {}
        #expect(records.all == [config])
    }
}
