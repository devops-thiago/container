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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import SystemPackage

public actor ClusterService {
    public typealias ContainerLister = @Sendable () async throws -> [ContainerSnapshot]

    private let store: FilesystemEntityStore<ClusterConfiguration>
    private let listContainers: ContainerLister
    private let log: Logger

    /// Counts the deletions this service has handled; see `adoptRecordless`.
    private var deletionCount: UInt64 = 0
    /// The value of `deletionCount` at the latest deletion of each name made while an adoption,
    /// which might have seen the name's nodes, was running.
    private var deletions: [String: UInt64] = [:]
    /// Adoptions in progress; `deletions` is emptied when none are.
    private var adoptionsInFlight = 0

    /// - Parameter root: Directory holding one subdirectory per cluster. Created if missing.
    public init(root: FilePath, listContainers: @escaping ContainerLister, log: Logger) throws {
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        self.store = try FilesystemEntityStore(path: root, type: "clusters", log: log)
        self.listContainers = listContainers
        self.log = log
    }

    /// Records the cluster and returns it. No node containers exist yet, so every node is reported stopped.
    public func create(configuration: ClusterConfiguration) async throws -> ClusterResource {
        if let existing = try await store.retrieve(configuration.name) {
            try await ensureReplaceable(existing)
            log.info("replacing stale cluster record", metadata: ["name": "\(configuration.name)"])
            try await store.upsert(configuration)
        } else {
            try await store.create(configuration)
        }
        guard let cluster = Self.resources(configurations: [configuration], snapshots: []).first else {
            throw ContainerizationError(.internalError, message: "failed to build cluster \(configuration.name)")
        }
        return cluster
    }

    /// Throws `.exists` unless `record` is stale: none of its node containers exist any more (e.g. a `--rm` cluster).
    private func ensureReplaceable(_ record: ClusterConfiguration) async throws {
        let alreadyExists = ContainerizationError(
            .exists,
            message: "cluster \(record.name) already exists; run 'container cluster delete --name \(record.name)' to remove it")

        let liveContainerIDs = Set(try await listContainers().map { $0.configuration.id })
        let hasLiveNode = record.nodes.contains { liveContainerIDs.contains($0.name) }
        guard !hasLiveNode else { throw alreadyExists }

        // The actor may have been re-entered while awaiting; only replace the record we inspected.
        let current = try await store.retrieve(record.name)
        guard current == nil || current == record else { throw alreadyExists }
    }

    public func get(name: String) async throws -> ClusterResource {
        var adoptedFrom: [ContainerSnapshot]?
        if try await store.retrieve(name) == nil {
            adoptedFrom = try await adoptRecordless(names: [name])
        }
        guard let configuration = try await store.retrieve(name) else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        let snapshots: [ContainerSnapshot]
        if let adoptedFrom {
            snapshots = adoptedFrom
        } else {
            snapshots = try await listContainers()
        }
        guard let cluster = Self.resources(configurations: [configuration], snapshots: snapshots).first else {
            throw ContainerizationError(.internalError, message: "failed to build cluster \(name)")
        }
        return cluster
    }

    public func list() async throws -> [ClusterResource] {
        let snapshots = try await adoptRecordless(names: nil)
        return Self.resources(configurations: try await store.list(), snapshots: snapshots)
    }

    /// Records each cluster whose node containers exist but that has no record, as clusters
    /// made by engines before 1.7.1 are, so that every path sees them. Restricted to `names`
    /// when given. Returns the container snapshots it worked from.
    ///
    /// Idempotent: a cluster with a record is never adopted again. Safe against a concurrent
    /// create, which records its cluster before making any node, so a cluster being created
    /// is never record-less; and an adoption only ever creates a record, so one written while
    /// the containers were being listed is kept. Safe against a concurrent delete, which
    /// removes the nodes and then the record: a name deleted while the containers were being
    /// listed is not adopted from nodes that listing may still have seen.
    @discardableResult
    private func adoptRecordless(names: Set<String>?) async throws -> [ContainerSnapshot] {
        let deletionsBefore = deletionCount
        adoptionsInFlight += 1
        defer {
            adoptionsInFlight -= 1
            if adoptionsInFlight == 0 { deletions.removeAll() }
        }
        let snapshots = try await listContainers()
        let recorded = Set(try await store.list().map(\.name))
        let adoptable = RecordlessClusters.configurations(from: snapshots, recorded: recorded, log: log)
            .filter { names?.contains($0.name) ?? true }
        for configuration in adoptable {
            if let deletedAt = deletions[configuration.name], deletedAt > deletionsBefore {
                log.debug("not adopting a cluster deleted while its nodes were listed", metadata: ["name": "\(configuration.name)"])
                continue
            }
            do {
                try await store.create(configuration)
                log.info(
                    "adopted cluster without a record",
                    metadata: ["name": "\(configuration.name)", "nodes": "\(configuration.nodes.count)"])
            } catch let error as ContainerizationError where error.code == .exists {
                // Recorded by a create since the store was read; that record stands.
            }
        }
        return snapshots
    }

    public func delete(name: String) async throws {
        guard ClusterResource.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "invalid cluster name \(name)")
        }
        // Noted even without a record: a record-less cluster's nodes are already gone when its
        // delete reaches here, and an adoption that listed them before must not record it.
        deletionCount += 1
        if adoptionsInFlight > 0 { deletions[name] = deletionCount }
        guard try await store.retrieve(name) != nil else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        try await store.delete(name)
    }

    /// Derives each cluster's status from its stored configuration and the live container snapshots.
    static func resources(configurations: [ClusterConfiguration], snapshots: [ContainerSnapshot]) -> [ClusterResource] {
        let byID = Dictionary(snapshots.map { ($0.configuration.id, $0) }, uniquingKeysWith: { first, _ in first })
        return configurations.sorted { $0.name < $1.name }.map { config in
            let nodes = config.nodes.map { node -> ClusterNodeState in
                guard let snapshot = byID[node.name] else {
                    return ClusterNodeState(name: node.name, status: .stopped)
                }
                let addresses = snapshot.networks.map { $0.ipv4Address.address.description }
                let ports = snapshot.configuration.publishedPorts.map { "\($0.hostPort)->\($0.containerPort)" }
                return ClusterNodeState(
                    name: node.name, status: snapshot.status,
                    addresses: addresses.isEmpty ? nil : addresses,
                    ports: ports.isEmpty ? nil : ports)
            }
            let up = nodes.filter { $0.status == .running }.count
            let state: ClusterState = up == 0 ? .stopped : (up == nodes.count ? .running : .degraded)
            return ClusterResource(configuration: config, status: ClusterStatus(state: state, nodes: nodes))
        }
    }
}
