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
import NIOHTTP1

/// The engine's volumes as the volume routes see them. The agent answers it from the API
/// server; tests answer it from a fake.
public protocol EngineVolumes: Sendable {
    func list() async throws -> [VolumeConfiguration]
    /// Makes a volume with the engine's `local` driver. One that exists already is an error the
    /// caller tells apart with `existing`.
    func create(name: String, driverOpts: [String: String], labels: [String: String]) async throws -> VolumeConfiguration
    /// Deletes a volume. With `requiredLabels`, the engine deletes it only if it carries them.
    func delete(_ name: String, requiredLabels: [String: String]?) async throws
    /// The bytes a volume holds, for what a prune reclaims.
    func diskUsage(_ name: String) async throws -> UInt64
}

/// A volume as `GET /volumes` and `GET /volumes/{name}` show it.
public struct DockerVolume: Encodable, Sendable, Equatable {
    public var Name: String
    public var Driver: String
    public var Mountpoint: String
    public var CreatedAt: String
    public var Labels: [String: String]
    public var Scope: String
    public var Options: [String: String]
}

public struct DockerVolumeList: Encodable, Sendable, Equatable {
    public var Volumes: [DockerVolume]
    public var Warnings: [String]
}

public struct DockerVolumePruneReport: Encodable, Sendable, Equatable {
    public var VolumesDeleted: [String]
    public var SpaceReclaimed: UInt64
}

/// `POST /volumes/create`'s body.
public struct DockerVolumeCreateBody: Decodable, Sendable {
    public var Name: String?
    public var Driver: String?
    public var DriverOpts: [String: String]?
    public var Labels: [String: String]?
    public var ClusterVolumeSpec: DockerIgnoredValue?
}

/// The engine's volumes in Docker's shapes, and the choices the volume routes make.
public enum VolumeMapper {
    /// What Docker labels an anonymous volume with; the engine has its own label for it.
    public static let dockerAnonymousLabel = "com.docker.volume.anonymous"
    /// The driver options a create may give: the engine's volume is a disk image of this size.
    public static let supportedDriverOptions: Set<String> = ["size"]

    public static func volume(_ volume: VolumeConfiguration) -> DockerVolume {
        var labels = volume.labels
        if labels.removeValue(forKey: VolumeConfiguration.anonymousLabel) != nil {
            labels[dockerAnonymousLabel] = ""
        }
        return DockerVolume(
            Name: volume.name,
            // The engine's only driver is the one Docker calls `local`.
            Driver: "local",
            Mountpoint: volume.source,
            CreatedAt: Date.ISO8601FormatStyle(timeZone: .gmt).format(volume.creationDate),
            Labels: labels,
            Scope: "local",
            Options: volume.options)
    }

    /// The labels and options an engine create gets, refused as dockerd and its local driver
    /// refuse them. A create without a name is anonymous.
    public static func createRequest(
        _ body: DockerVolumeCreateBody, newName: () -> String
    ) throws(DockerAPIError) -> (name: String, driverOpts: [String: String], labels: [String: String]) {
        let given = body.Name ?? ""
        let name = given.isEmpty ? newName() : given
        let driver = body.Driver ?? ""
        guard driver.isEmpty || driver == "local" else {
            throw .notFound("create \(name): error looking up volume plugin \(driver): plugin \"\(driver)\" not found")
        }
        if name.count == 1 {
            throw .badRequest("create \(name): volume name is too short, names should be at least two alphanumeric characters")
        }
        guard VolumeStorage.isValidVolumeName(name) else {
            throw .badRequest(
                "create \(name): \"\(name)\" includes invalid characters for a local volume name, only \"[a-zA-Z0-9][a-zA-Z0-9_.-]\" are allowed. If you intended to pass a host directory, use absolute path"
            )
        }
        let options = body.DriverOpts ?? [:]
        for key in options.keys.sorted() where !supportedDriverOptions.contains(key) {
            throw .badRequest("create \(name): invalid option: \"\(key)\": SiliconShip's local driver takes only size")
        }
        var labels = body.Labels ?? [:]
        for key in labels.keys where key == VolumeConfiguration.anonymousLabel {
            throw .badRequest("create \(name): label \(key) is reserved")
        }
        if given.isEmpty || labels.removeValue(forKey: dockerAnonymousLabel) != nil {
            labels[VolumeConfiguration.anonymousLabel] = ""
        }
        return (name, options, labels)
    }

    /// The containers that mount each volume, running or not, by Docker ID.
    public static func users(_ containers: [DockerContainer]) -> [String: [String]] {
        var users: [String: [String]] = [:]
        for container in containers {
            for name in Set(container.snapshot.configuration.mounts.compactMap(\.volumeName)) {
                users[name, default: []].append(container.dockerID)
            }
        }
        return users
    }

    static let listAccepted: Set<String> = ["name", "label", "dangling", "driver"]

    /// The `filters` of `GET /volumes`: `name` as a pattern, `label`, `dangling` (no container
    /// mounts it) and `driver`.
    public static func list(
        _ volumes: [VolumeConfiguration], filters: [String: [String]], users: [String: [String]]
    ) throws(DockerAPIError) -> [VolumeConfiguration] {
        try DockerFilters.validate(filters, accepted: listAccepted)
        let dangling = filters["dangling"] == nil ? nil : try DockerFilters.bool(filters, "dangling", default: false)
        return volumes.filter { volume in
            let shown = Self.volume(volume)
            return DockerFilters.patternMatch(filters["name"], volume.name) && DockerFilters.labelsMatch(filters["label"], shown.Labels)
                && DockerFilters.exactMatch(filters["driver"], shown.Driver)
                && dangling.map { $0 == (users[volume.name] ?? []).isEmpty } ?? true
        }.sorted { $0.name < $1.name }
    }

    static let pruneAccepted: Set<String> = ["label", "label!", "all"]

    /// The volumes `POST /volumes/prune` removes: those no container mounts, running or not,
    /// matching the label filters, and only the anonymous ones unless `all=true`, as dockerd
    /// does since API 1.42. A named volume holds data somebody chose to keep.
    public static func pruneSelection(
        _ volumes: [VolumeConfiguration], filters: [String: [String]], users: [String: [String]]
    ) throws(DockerAPIError) -> [VolumeConfiguration] {
        try DockerFilters.validate(filters, accepted: pruneAccepted)
        var all = false
        if let values = filters["all"] {
            guard values.count == 1 else {
                throw .badRequest("invalid filter 'all=[\(values.joined(separator: " "))]': only one value is expected")
            }
            guard let parsed = goBool(values[0]) else {
                throw .badRequest("invalid filter 'all': strconv.ParseBool: parsing \"\(values[0])\": invalid syntax")
            }
            all = parsed
        }
        return volumes.filter { volume in
            (users[volume.name] ?? []).isEmpty && (all || volume.isAnonymous) && DockerFilters.pruneLabelsMatch(filters, Self.volume(volume).Labels)
        }.sorted { $0.name < $1.name }
    }

    /// Go's `strconv.ParseBool`.
    static func goBool(_ text: String) -> Bool? {
        switch text {
        case "1", "t", "T", "true", "TRUE", "True": true
        case "0", "f", "F", "false", "FALSE", "False": false
        default: nil
        }
    }

    /// The `key=value` label filters, which the engine can check itself when it deletes. A
    /// filter on a key alone is checked here only.
    static func requiredLabels(_ filters: [String: [String]]) -> [String: String]? {
        var required: [String: String] = [:]
        for condition in filters["label"] ?? [] {
            let parts = condition.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { required[String(parts[0])] = String(parts[1]) }
        }
        return required.isEmpty ? nil : required
    }
}

/// `GET /volumes`, `POST /volumes/create`, `GET /volumes/{name}`, `DELETE /volumes/{name}` and
/// `POST /volumes/prune`.
public enum VolumeRoutes {
    /// - Parameter events: where creates and removals are reported; nil reports nothing.
    public static func register(
        on router: inout DockerRouter, engine: some EngineVolumes, containers: some EngineContainers, identities: DockerIdentityStore,
        events: DockerEventBus? = nil
    ) {
        let routes = Routes(engine: engine, containers: containers, identities: identities, events: events)
        router.add(.GET, "/volumes") { request, _ in try await routes.list(request) }
        router.add(.POST, "/volumes/create") { request, _ in try await routes.create(request) }
        router.add(.POST, "/volumes/prune") { request, _ in try await routes.prune(request) }
        router.add(.GET, "/volumes/{name}") { _, parameters in try await routes.inspect(try parameters["name"]) }
        router.add(.DELETE, "/volumes/{name}") { request, parameters in try await routes.delete(try parameters["name"], request) }
    }

    struct Routes<Engine: EngineVolumes, Containers: EngineContainers>: Sendable {
        let engine: Engine
        let containers: Containers
        let identities: DockerIdentityStore
        let events: DockerEventBus?

        /// A volume event as dockerd reports one: by name, with its driver.
        func report(_ action: String, _ name: String) async {
            await events?.publish(type: "volume", action: action, actorID: name, attributes: ["driver": "local"])
        }

        func users() async throws -> [String: [String]] {
            VolumeMapper.users(await identities.join(try await containers.list()))
        }

        func list(_ request: DockerRequest) async throws -> DockerResponse {
            let volumes = try VolumeMapper.list(try await engine.list(), filters: try request.filters(), users: try await users())
            return try .json(DockerVolumeList(Volumes: volumes.map(VolumeMapper.volume), Warnings: []))
        }

        func find(_ name: String) async throws -> VolumeConfiguration? {
            try await engine.list().first { $0.name == name }
        }

        func inspect(_ name: String) async throws -> DockerResponse {
            guard let volume = try await find(name) else { throw DockerAPIError.notFound("get \(name): no such volume") }
            return try .json(VolumeMapper.volume(volume))
        }

        /// A name that exists answers with that volume, as dockerd does.
        func create(_ request: DockerRequest) async throws -> DockerResponse {
            var generator = SystemRandomNumberGenerator()
            let (name, options, labels) = try VolumeMapper.createRequest(
                try request.decode(DockerVolumeCreateBody.self), newName: { DockerIdentityTable.randomID(using: &generator) })
            if let existing = try await find(name) {
                return try .json(VolumeMapper.volume(existing), status: .created)
            }
            let volume: VolumeConfiguration
            do {
                volume = try await engine.create(name: name, driverOpts: options, labels: labels)
            } catch let error as DockerAPIError where error.status == .conflict {
                // Made between the look and the create.
                guard let existing = try await find(name) else { throw error }
                volume = existing
            }
            await report("create", volume.name)
            return try .json(VolumeMapper.volume(volume), status: .created)
        }

        /// 409 while any container mounts it, running or not; with `force`, a missing volume is
        /// not an error.
        func delete(_ name: String, _ request: DockerRequest) async throws -> DockerResponse {
            let force = try request.bool("force")
            guard try await find(name) != nil else {
                if force { return .empty() }
                throw DockerAPIError.notFound("get \(name): no such volume")
            }
            if let users = try await users()[name], !users.isEmpty {
                throw DockerAPIError.conflict("remove \(name): volume is in use - [\(users.joined(separator: ", "))]")
            }
            try await engine.delete(name, requiredLabels: nil)
            await report("destroy", name)
            return .empty()
        }

        /// Removes what `VolumeMapper.pruneSelection` picks, skipping one it cannot remove. The
        /// `key=value` label filters are also handed to the engine, which refuses a volume that
        /// does not carry them.
        func prune(_ request: DockerRequest) async throws -> DockerResponse {
            let filters = try request.filters()
            let selected = try VolumeMapper.pruneSelection(try await engine.list(), filters: filters, users: try await users())
            let required = VolumeMapper.requiredLabels(filters)
            var deleted: [String] = []
            var reclaimed: UInt64 = 0
            for volume in selected {
                let size = (try? await engine.diskUsage(volume.name)) ?? 0
                do {
                    try await engine.delete(volume.name, requiredLabels: required)
                } catch {
                    continue
                }
                deleted.append(volume.name)
                reclaimed += size
                await report("destroy", volume.name)
            }
            return try .json(DockerVolumePruneReport(VolumesDeleted: deleted, SpaceReclaimed: reclaimed))
        }
    }
}
