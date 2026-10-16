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
import CryptoKit
import Foundation

/// The labels this service puts on the containers it creates. They are written once, at create:
/// the engine has no way to change a container's labels afterwards.
public enum DockerLabels {
    public static let prefix = "dev.siliconship.docker."
    /// The Docker name at create, without its leading `/`. A rename is kept by the identity
    /// store, so this is where a name starts, not necessarily where it is now.
    public static let name = prefix + "name"
    /// The 64-hex Docker ID, whose first 12 characters are the engine's ID.
    public static let id = prefix + "id"
    /// The image as the client named it (`alpine`), where the engine keeps it normalized
    /// (`docker.io/library/alpine:latest`).
    public static let image = prefix + "image"
    /// The image's ID: the digest of its config for the platform it runs as.
    public static let imageID = prefix + "image-id"

    /// Keys a client may not set: this service's own, and the one that makes a container
    /// engine infrastructure.
    static func isReserved(_ key: String) -> Bool {
        key.hasPrefix(prefix) || key == ResourceLabelKeys.plugin
    }
}

/// What a Docker client said at create that the engine's configuration has no place for, kept
/// by the identity store so that inspect can echo it and attach can honour it.
public struct DockerContainerExtras: Codable, Sendable, Equatable {
    public var image: String
    public var imageID: String
    public var entrypoint: [String]?
    public var cmd: [String]?
    public var attachStdin: Bool
    public var attachStdout: Bool
    public var attachStderr: Bool
    public var openStdin: Bool
    public var stdinOnce: Bool
    public var exposedPorts: [String]
    public var volumes: [String]
    /// `bridge` for the default network, as dockerd reports it.
    public var networkMode: String
    public var autoRemove: Bool
    public var publishAllPorts: Bool
    public var domainname: String
    /// The volumes this container's create made for it, which `DELETE ?v=1` removes.
    public var anonymousVolumes: [String]

    public init(
        image: String, imageID: String, entrypoint: [String]? = nil, cmd: [String]? = nil, attachStdin: Bool = false, attachStdout: Bool = false,
        attachStderr: Bool = false, openStdin: Bool = false, stdinOnce: Bool = false, exposedPorts: [String] = [], volumes: [String] = [],
        networkMode: String = "bridge", autoRemove: Bool = false, publishAllPorts: Bool = false, domainname: String = "",
        anonymousVolumes: [String] = []
    ) {
        self.image = image
        self.imageID = imageID
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.exposedPorts = exposedPorts
        self.volumes = volumes
        self.networkMode = networkMode
        self.autoRemove = autoRemove
        self.publishAllPorts = publishAllPorts
        self.domainname = domainname
        self.anonymousVolumes = anonymousVolumes
    }
}

/// One container this service knows by more than its engine ID.
public struct DockerContainerRecord: Codable, Sendable, Equatable {
    public var engineID: String
    /// The engine's identity for this exact creation of `engineID`, so that a record does not
    /// outlive its container into another one made under the same ID.
    public var incarnation: String
    public var dockerID: String
    public var name: String
    public var extras: DockerContainerExtras?

    public init(engineID: String, incarnation: String, dockerID: String, name: String, extras: DockerContainerExtras? = nil) {
        self.engineID = engineID
        self.incarnation = incarnation
        self.dockerID = dockerID
        self.name = name
        self.extras = extras
    }
}

/// An engine container as a Docker client sees it.
public struct DockerContainer: Sendable {
    public var snapshot: ContainerSnapshot
    public var dockerID: String
    /// Without the leading `/`.
    public var name: String
    public var extras: DockerContainerExtras?

    public var engineID: String { snapshot.id }

    public init(snapshot: ContainerSnapshot, dockerID: String, name: String, extras: DockerContainerExtras? = nil) {
        self.snapshot = snapshot
        self.dockerID = dockerID
        self.name = name
        self.extras = extras
    }
}

/// The mapping between Docker identities and engine containers, as a value.
///
/// A container this service created carries its Docker ID and name in labels and has a record.
/// The record wins, since a rename can only change the record. A labelled container without a
/// record (the store was lost) gets one back from its labels. Any other container was made by
/// `container run` or the app: its Docker ID is the SHA-256 of its engine ID, and its name is its
/// engine ID, until it is renamed and so gets a record of its own.
public struct DockerIdentityTable: Sendable, Equatable {
    public private(set) var records: [String: DockerContainerRecord]

    public init(records: [DockerContainerRecord] = []) {
        self.records = Dictionary(records.map { ($0.engineID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The Docker ID of a container this service did not create.
    public static func foreignID(engineID: String) -> String {
        SHA256.hash(data: Data(engineID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isDockerID(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Joins every engine container with its identity, and forgets records whose container is
    /// gone or was made again under the same engine ID.
    public mutating func join(_ snapshots: [ContainerSnapshot]) -> [DockerContainer] {
        var kept: [String: DockerContainerRecord] = [:]
        let containers = snapshots.map { snapshot -> DockerContainer in
            if let record = records[snapshot.id], Self.sameIncarnation(record.incarnation, snapshot.incarnation) {
                kept[snapshot.id] = record
                return DockerContainer(snapshot: snapshot, dockerID: record.dockerID, name: record.name, extras: record.extras)
            }
            let labels = snapshot.configuration.labels
            if let id = labels[DockerLabels.id], Self.isDockerID(id), id.hasPrefix(snapshot.id) {
                let record = DockerContainerRecord(
                    engineID: snapshot.id, incarnation: snapshot.incarnation, dockerID: id, name: labels[DockerLabels.name] ?? snapshot.id)
                kept[snapshot.id] = record
                return DockerContainer(snapshot: snapshot, dockerID: record.dockerID, name: record.name)
            }
            return DockerContainer(snapshot: snapshot, dockerID: Self.foreignID(engineID: snapshot.id), name: snapshot.id)
        }
        records = kept
        return containers
    }

    /// An empty incarnation comes from an engine that did not report one; it matches anything.
    private static func sameIncarnation(_ recorded: String, _ current: String) -> Bool {
        recorded.isEmpty || current.isEmpty || recorded == current
    }

    public mutating func insert(_ record: DockerContainerRecord) {
        records[record.engineID] = record
    }

    public mutating func remove(engineID: String) {
        records[engineID] = nil
    }

    /// Gives `container` a new name, making it a record if it had none.
    public mutating func rename(_ container: DockerContainer, to name: String) {
        var record =
            records[container.engineID]
            ?? DockerContainerRecord(
                engineID: container.engineID, incarnation: container.snapshot.incarnation, dockerID: container.dockerID, name: container.name,
                extras: container.extras)
        record.name = name
        records[container.engineID] = record
    }

    /// The container a client's reference means, by dockerd's rules: a full ID, then an exact
    /// name with or without its `/`, then a unique ID prefix.
    public static func resolve(_ reference: String, in containers: [DockerContainer]) throws(DockerAPIError) -> DockerContainer {
        guard !reference.isEmpty else {
            throw .badRequest("invalid name or ID supplied: \"\"")
        }
        if let byID = containers.first(where: { $0.dockerID == reference }) {
            return byID
        }
        let name = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        if let byName = containers.first(where: { $0.name == name }) {
            return byName
        }
        let matches = containers.filter { $0.dockerID.hasPrefix(reference) }
        guard matches.count < 2 else {
            throw .badRequest("multiple IDs found with provided prefix: \(reference)")
        }
        guard let match = matches.first else {
            throw .notFound("No such container: \(reference)")
        }
        return match
    }

    /// dockerd's pattern for a container name, after its optional leading `/`.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-zA-Z0-9][a-zA-Z0-9_.-]+/#) != nil
    }

    /// A name for a client that gave none, in the spirit of dockerd's: an adjective and a name.
    static func generatedName<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let adjectives = [
            "bold", "brave", "calm", "clever", "eager", "fond", "gentle", "happy", "jolly", "keen", "lucid", "merry", "nimble", "proud", "quiet",
            "sharp", "swift", "tender", "vivid", "witty",
        ]
        let names = [
            "babbage", "curie", "dijkstra", "euler", "fermi", "gauss", "hopper", "kepler", "lamarr", "lovelace", "meitner", "noether", "pascal",
            "ramanujan", "shannon", "turing", "volta", "wozniak", "yalow", "zuse",
        ]
        let adjective = adjectives[Int.random(in: 0..<adjectives.count, using: &generator)]
        let name = names[Int.random(in: 0..<names.count, using: &generator)]
        return "\(adjective)_\(name)"
    }

    /// 64 random hex digits.
    static func randomID<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<4).map { _ in
            let value = UInt64.random(in: 0...UInt64.max, using: &generator)
            let hex = String(value, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }
}

/// Where the identity table is kept between runs.
public protocol DockerIdentityPersistence: Sendable {
    func load() throws -> [DockerContainerRecord]
    func save(_ records: [DockerContainerRecord]) throws
}

/// The identity table as a JSON file only its owner can read.
public struct DockerIdentityFile: DockerIdentityPersistence {
    public static let fileName = "containers.json"

    struct Document: Codable {
        var version: Int
        var containers: [DockerContainerRecord]
    }

    public let url: URL

    public init(directory: URL) {
        url = directory.appending(path: Self.fileName)
    }

    public func load() throws -> [DockerContainerRecord] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)).containers
    }

    public func save(_ records: [DockerContainerRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, containers: records.sorted { $0.engineID < $1.engineID }))
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}

/// A name and ID set aside for a create in flight, so that two creates cannot both take them.
public struct DockerIdentityReservation: Sendable, Equatable {
    public let name: String
    public let dockerID: String

    public var engineID: String { String(dockerID.prefix(DockerIdentityStore.engineIDLength)) }
}

/// The identity table shared by the routes, kept on disk after every change.
public actor DockerIdentityStore {
    /// How much of a Docker ID is the engine's ID: what `docker ps` shows, so that it and
    /// `container ls` agree.
    public static let engineIDLength = 12

    private var table: DockerIdentityTable
    private var reserved: [String: DockerIdentityReservation] = [:]
    private let persistence: (any DockerIdentityPersistence)?
    private var generator: any RandomNumberGenerator

    /// A store that starts from what `persistence` holds. One that cannot be read starts empty:
    /// the labels on the containers this service made bring their identities back.
    public init(persistence: (any DockerIdentityPersistence)?, generator: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.persistence = persistence
        self.generator = generator
        table = DockerIdentityTable(records: (try? persistence?.load()) ?? [])
    }

    public var records: [DockerContainerRecord] {
        table.records.values.sorted { $0.engineID < $1.engineID }
    }

    /// The engine's containers as Docker sees them.
    public func join(_ snapshots: [ContainerSnapshot]) -> [DockerContainer] {
        let before = table
        let containers = table.join(snapshots)
        if table != before {
            // Saving again at the next change is as good as saving now; a failure here only
            // means a label has to bring a name back after a restart.
            try? save()
        }
        return containers
    }

    /// Sets aside `name` (or a generated one) and a new Docker ID for a create.
    public func reserve(name requested: String?, among containers: [DockerContainer]) throws(DockerAPIError) -> DockerIdentityReservation {
        let name: String
        if let requested {
            let bare = requested.hasPrefix("/") ? String(requested.dropFirst()) : requested
            guard DockerIdentityTable.isValidName(bare) else {
                throw .badRequest("Invalid container name (\(requested)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
            }
            try checkFree(bare, among: containers)
            name = bare
        } else {
            var candidate = DockerIdentityTable.generatedName(using: &generator)
            var attempt = 0
            while (try? checkFree(candidate, among: containers)) == nil {
                attempt += 1
                candidate = DockerIdentityTable.generatedName(using: &generator) + (attempt > 3 ? "\(attempt)" : "")
            }
            name = candidate
        }
        let taken = Set(containers.map(\.engineID)).union(reserved.values.map(\.engineID))
        var id = DockerIdentityTable.randomID(using: &generator)
        while taken.contains(String(id.prefix(Self.engineIDLength))) {
            id = DockerIdentityTable.randomID(using: &generator)
        }
        let reservation = DockerIdentityReservation(name: name, dockerID: id)
        reserved[name] = reservation
        return reservation
    }

    private func checkFree(_ name: String, among containers: [DockerContainer]) throws(DockerAPIError) {
        if let holder = containers.first(where: { $0.name == name }) {
            throw Self.nameConflict(name, holder: holder.dockerID)
        }
        if let holder = reserved[name] {
            throw Self.nameConflict(name, holder: holder.dockerID)
        }
        // A create or rename that finished after `containers` was read holds its name here.
        if let holder = table.records.values.first(where: { $0.name == name }) {
            throw Self.nameConflict(name, holder: holder.dockerID)
        }
    }

    static func nameConflict(_ name: String, holder: String) -> DockerAPIError {
        .conflict(
            "Conflict. The container name \"/\(name)\" is already in use by container \"\(holder)\". You have to remove (or rename) that container to be able to reuse that name."
        )
    }

    /// Records a create that succeeded and lets its reservation go.
    public func commit(_ reservation: DockerIdentityReservation, incarnation: String, extras: DockerContainerExtras?) {
        reserved[reservation.name] = nil
        table.insert(
            DockerContainerRecord(
                engineID: reservation.engineID, incarnation: incarnation, dockerID: reservation.dockerID, name: reservation.name, extras: extras))
        try? save()
    }

    /// Lets the reservation of a create that failed go.
    public func release(_ reservation: DockerIdentityReservation) {
        reserved[reservation.name] = nil
    }

    /// Renames `container`. The engine's label keeps the first name; this store keeps the
    /// current one.
    public func rename(_ container: DockerContainer, to requested: String, among containers: [DockerContainer]) throws(DockerAPIError) {
        let name = requested.hasPrefix("/") ? String(requested.dropFirst()) : requested
        guard !name.isEmpty else {
            throw .badRequest("Neither old nor new names may be empty")
        }
        guard name != container.name else {
            throw .badRequest("Renaming a container with the same name as its current name")
        }
        guard DockerIdentityTable.isValidName(name) else {
            throw .badRequest("Invalid container name (\(requested)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        do {
            try checkFree(name, among: containers)
        } catch {
            throw .conflict("Error when allocating new name: \(error.message)")
        }
        table.rename(container, to: name)
        do {
            try save()
        } catch {
            throw .internalError("could not keep the new name: \(error)")
        }
    }

    /// Keeps `container`'s identity when it was deleted and made again under the same engine ID,
    /// as connecting it to a network does: the new incarnation would otherwise lose its record.
    public func recreated(_ container: DockerContainer, incarnation: String) {
        table.insert(
            DockerContainerRecord(
                engineID: container.engineID, incarnation: incarnation, dockerID: container.dockerID, name: container.name, extras: container.extras))
        try? save()
    }

    /// Forgets a container that was deleted.
    public func forget(engineID: String) {
        guard table.records[engineID] != nil else { return }
        table.remove(engineID: engineID)
        try? save()
    }

    private func save() throws {
        try persistence?.save(records)
    }
}
