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
import Foundation
import Logging
import Testing

@testable import ContainerCluster

private actor ReadinessCluster: ClusterStartupOperations, K8sClusterContainers {
    enum Failure: Error, Equatable { case missing, ownership, notRegistered, cniNotReady }
    private var snapshots: [String: ContainerSnapshot] = [:]
    private var registered: Set<String> = []
    private let record: ReadinessFileFixture
    private let legacy: Bool
    private var trusted = true
    private var healthyCNI = false
    private var holdAuthorization = false
    private let authorizationHold = AsyncStream<Void>.makeStream()
    private let authorizationSeen = AsyncStream<Void>.makeStream()
    nonisolated let authorizationEvents: AsyncStream<Void>
    private(set) var starts: [String] = []
    private(set) var deletes = 0
    private(set) var policyReads = 0
    private(set) var readinessCalls = 0
    private(set) var registrationChecks: [[String]] = []
    private(set) var configurationsWritten = 0

    init(legacy: Bool = false) throws {
        self.legacy = legacy
        record = try ReadinessFileFixture()
        authorizationEvents = authorizationSeen.stream
    }

    func provision(_ name: String, role: String) throws {
        var labels = [
            ResourceLabelKeys.plugin: legacy ? ResourcePluginValues.legacyKubernetes : ClusterHelper.pluginName,
            ResourceLabelKeys.role: role,
            "container.cluster.readiness": "registered",  // Untrusted labels must not select policy.
        ]
        if !legacy { labels[ResourceLabelKeys.cluster] = "dev" }
        let labelsJSON = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
        let json = """
            {"configuration":{"id":"\(name)",
            "image":{"reference":"fixture:latest","descriptor":{"mediaType":"m","digest":"sha256:\(String(repeating: "a", count: 64))","size":1}},
            "initProcess":{"executable":"/bin/sh","arguments":[],"environment":[],"workingDirectory":"/","terminal":false,"user":{"id":{"uid":0,"gid":0}},"rlimits":[],"supplementalGroups":[]},
            "resources":{"cpus":1,"memoryInBytes":2147483648},"labels":\(labelsJSON)},
            "incarnation":"inc-\(name)","status":"running","networks":[]}
            """
        snapshots[name] = try JSONDecoder().decode(ContainerSnapshot.self, from: Data(json.utf8))
    }
    func register(_ name: String) { registered.insert(name) }
    func forgetRegistration(_ name: String) { registered.remove(name) }
    func setCNI(_ healthy: Bool) { healthyCNI = healthy }
    func requireAdoption() { trusted = false }
    func pauseAuthorization() { holdAuthorization = true }
    func removePolicy() throws { try FileManager.default.removeItem(at: record.file) }
    func policy() throws -> ClusterReadinessPolicy? { try record.read() }
    func states() -> [RuntimeStatus] { snapshots.values.map(\.status) }

    func get(id: String) throws -> ContainerSnapshot {
        guard let node = snapshots[id] else { throw Failure.missing }
        return node
    }
    func controlPlane(name: String) throws -> ContainerSnapshot { try get(id: name) }
    func listNodes() -> [ContainerSnapshot] { Array(snapshots.values) }
    func nodes() -> [ContainerSnapshot] { Array(snapshots.values) }
    func authorize(_ nodes: [ContainerSnapshot], name: String, adoptLegacy: Bool) async throws {
        guard trusted || adoptLegacy else { throw Failure.ownership }
        if holdAuthorization {
            authorizationSeen.continuation.yield(())
            var iterator = authorizationHold.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
    func start(_ node: ContainerSnapshot) throws {
        guard snapshots[node.id] != nil else { throw Failure.missing }
        starts.append(node.id)
        snapshots[node.id]?.status = .running
    }
    func pinKubeconfig(name: String) {}
    func storedPolicy(name: String) throws -> ClusterReadinessPolicy? {
        policyReads += 1
        return try record.read(name: name)
    }
    func storePolicy(_ policy: ClusterReadinessPolicy, name: String) throws { try record.store(policy, name: name) }
    func waitForReady(name: String) throws {
        readinessCalls += 1
        guard healthyCNI else { throw Failure.cniNotReady }
        guard Set(snapshots.keys).isSubset(of: registered) else { throw Failure.notRegistered }
    }
    func waitForRegistered(name: String, nodes: [String]) throws {
        registrationChecks.append(nodes)
        guard Set(nodes).isSubset(of: registered) else { throw Failure.notRegistered }
    }
    func writeKubeconfig(name: String) { configurationsWritten += 1 }
    func stop(id: String, requiredLabels: [String: String], expectedIncarnation: String) throws {
        let node = try get(id: id)
        guard node.incarnation == expectedIncarnation,
            requiredLabels.allSatisfy({ node.configuration.labels[$0.key] == $0.value })
        else { throw Failure.ownership }
        snapshots[id]?.status = .stopped
    }
    func delete(id: String, requiredLabels: [String: String], expectedIncarnation: String) {
        deletes += 1
        snapshots.removeValue(forKey: id)
    }
    func teardown(_ name: String) {
        deletes += 1
        snapshots.removeValue(forKey: name)
    }
}

private struct ReadinessNode: NodeProvisioner {
    let cluster: ReadinessCluster
    let roles: [String]
    func provision(name: String, log: Logger) async throws { try await cluster.provision(name, role: roles[0]) }
    func address(name: String, log: Logger) async throws -> String { "10.0.0.2" }
    func join(name: String, controlPlaneEndpoint: String, token: String, caCertHash: String, log: Logger) async throws {
        await cluster.register(name)
    }
    func waitForReady(name: String, log: Logger) async throws { try await cluster.waitForReady(name: name) }
    func waitForRegistered(name: String, log: Logger) async throws { try await cluster.waitForRegistered(name: "dev", nodes: [name]) }
    func teardown(name: String, log: Logger) async throws { await cluster.teardown(name) }
}

struct ClusterReadinessLifecycleTests {
    private let log = Logger(label: "cluster-readiness-tests")

    private func create(_ cluster: ReadinessCluster, cni: String? = "NONE", workers: Int = 2) async throws {
        let policy = ClusterReadinessPolicy.forCreation(cniManifestPath: cni)
        try await K8sClusters.provisionCluster(
            name: "dev", controlPlane: ReadinessNode(cluster: cluster, roles: [StandardRoles.controlPlane]),
            workers: (0..<workers).map {
                .init(name: "dev-worker-\($0 + 1)", provisioner: ReadinessNode(cluster: cluster, roles: [StandardRoles.worker]))
            },
            initializeControlPlane: { _, _, _ in
                await cluster.register("dev")
                return .init(token: "fixture", caCertHash: "sha256:fixture")
            },
            readinessPolicy: policy,
            persistReadiness: { try await cluster.storePolicy($0, name: "dev") }, log: log)
    }

    private func start(_ cluster: ReadinessCluster, readiness: ClusterReadinessPolicy? = nil, adoptLegacy: Bool = false) async throws {
        try await K8sClusters.start(name: "dev", adoptLegacy: adoptLegacy, readiness: readiness, operations: cluster, log: log)
    }

    @Test func noCNICreateStopStartIncludesEveryWorker() async throws {
        let cluster = try ReadinessCluster()
        try await create(cluster)
        #expect(try await cluster.policy() == .registered)
        try await K8sClusters.stop(name: "dev", containers: cluster, log: log)
        #expect(await cluster.states().allSatisfy { $0 == .stopped })
        try await start(cluster)
        #expect(await cluster.starts == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(await cluster.registrationChecks.last == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(await cluster.readinessCalls == 0)
        #expect(await cluster.states().count == 3)
        #expect(await cluster.states().allSatisfy { $0 == .running })
        #expect(await cluster.deletes == 0)
    }

    @Test func ordinaryBrokenCNIIsNotTreatedAsIntentionalNoCNI() async throws {
        let cluster = try ReadinessCluster()
        await cluster.setCNI(true)
        try await create(cluster, cni: nil)
        await cluster.setCNI(false)
        try await K8sClusters.stop(name: "dev", containers: cluster, log: log)
        await #expect(throws: ReadinessCluster.Failure.cniNotReady) { try await start(cluster) }
        #expect(try await cluster.policy() == .ready)
        #expect(await cluster.registrationChecks.isEmpty)
        #expect(await cluster.deletes == 0)
    }

    @Test func legacyK8sNodesNeedExplicitPolicyAndIndependentAdoption() async throws {
        let cluster = try ReadinessCluster(legacy: true)
        try await create(cluster)
        try await cluster.removePolicy()
        try await K8sClusters.stop(name: "dev", containers: cluster, log: log)
        await cluster.requireAdoption()
        await #expect(throws: ReadinessCluster.Failure.ownership) { try await start(cluster, readiness: .registered) }
        #expect(await cluster.starts.isEmpty)
        #expect(await cluster.policyReads == 0)
        await #expect(throws: ReadinessCluster.Failure.cniNotReady) { try await start(cluster, adoptLegacy: true) }
        try await start(cluster, readiness: .registered, adoptLegacy: true)
        #expect(try await cluster.policy() == .registered)
        #expect(await cluster.registrationChecks.last == ["dev", "dev-worker-1", "dev-worker-2"])
        #expect(await cluster.deletes == 0)
    }

    @Test func installingCNILaterCanSelectFullReadinessAndFailureDoesNotRevertIt() async throws {
        let cluster = try ReadinessCluster()
        try await create(cluster)
        await #expect(throws: ReadinessCluster.Failure.cniNotReady) { try await start(cluster, readiness: .ready) }
        #expect(try await cluster.policy() == .ready)
        await cluster.setCNI(true)
        try await K8sClusters.stop(name: "dev", containers: cluster, log: log)
        try await start(cluster)
        await cluster.setCNI(false)
        await #expect(throws: ReadinessCluster.Failure.cniNotReady) { try await start(cluster) }
        #expect(try await cluster.policy() == .ready)
    }

    @Test func missingWorkerRegistrationStillFailsNoCNIStart() async throws {
        let cluster = try ReadinessCluster()
        try await create(cluster)
        await cluster.forgetRegistration("dev-worker-2")
        await #expect(throws: ReadinessCluster.Failure.notRegistered) { try await start(cluster) }
        #expect(await cluster.deletes == 0)
    }

    @Test func cancellingStartDoesNotDeleteOrStartExistingNodes() async throws {
        let cluster = try ReadinessCluster()
        try await create(cluster)
        try await K8sClusters.stop(name: "dev", containers: cluster, log: log)
        await cluster.pauseAuthorization()
        let operation = Task { try await start(cluster) }
        defer { operation.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var events = cluster.authorizationEvents.makeAsyncIterator()
                _ = await events.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ReadinessCluster.Failure.missing
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await cluster.starts.isEmpty)
        #expect(await cluster.states().count == 3)
        #expect(await cluster.states().allSatisfy { $0 == .stopped })
        #expect(await cluster.deletes == 0)
    }
}
