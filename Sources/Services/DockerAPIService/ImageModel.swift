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

/// An image config blob as the image spec writes it, with the Docker fields `ImageConfig`
/// leaves out (`ExposedPorts`, `Volumes`, `Healthcheck`, `OnBuild`). Every field is optional:
/// what an image does not say is not invented.
public struct DockerImageConfigDocument: Codable, Sendable, Equatable {
    public struct Config: Codable, Sendable, Equatable {
        public var User: String?
        public var ExposedPorts: [String: DockerEmptyObject]?
        public var Env: [String]?
        public var Entrypoint: [String]?
        public var Cmd: [String]?
        public var Volumes: [String: DockerEmptyObject]?
        public var WorkingDir: String?
        public var Labels: [String: String]?
        public var StopSignal: String?
        public var ArgsEscaped: Bool?
        public var Healthcheck: DockerHealthConfig?
        public var OnBuild: [String]?
        public var Shell: [String]?

        public init(
            User: String? = nil, ExposedPorts: [String: DockerEmptyObject]? = nil, Env: [String]? = nil, Entrypoint: [String]? = nil,
            Cmd: [String]? = nil, Volumes: [String: DockerEmptyObject]? = nil, WorkingDir: String? = nil, Labels: [String: String]? = nil,
            StopSignal: String? = nil
        ) {
            self.User = User
            self.ExposedPorts = ExposedPorts
            self.Env = Env
            self.Entrypoint = Entrypoint
            self.Cmd = Cmd
            self.Volumes = Volumes
            self.WorkingDir = WorkingDir
            self.Labels = Labels
            self.StopSignal = StopSignal
        }
    }

    public struct RootFS: Codable, Sendable, Equatable {
        public var type: String?
        public var diffIDs: [String]?

        enum CodingKeys: String, CodingKey {
            case type
            case diffIDs = "diff_ids"
        }

        public init(type: String? = "layers", diffIDs: [String]?) {
            self.type = type
            self.diffIDs = diffIDs
        }
    }

    public struct History: Codable, Sendable, Equatable {
        public var created: String?
        public var createdBy: String?
        public var author: String?
        public var comment: String?
        public var emptyLayer: Bool?

        enum CodingKeys: String, CodingKey {
            case created
            case createdBy = "created_by"
            case author
            case comment
            case emptyLayer = "empty_layer"
        }

        public init(created: String? = nil, createdBy: String? = nil, comment: String? = nil, emptyLayer: Bool? = nil) {
            self.created = created
            self.createdBy = createdBy
            self.comment = comment
            self.emptyLayer = emptyLayer
        }
    }

    public var created: String?
    public var author: String?
    public var architecture: String?
    public var os: String?
    public var osVersion: String?
    public var variant: String?
    public var config: Config?
    public var rootfs: RootFS?
    public var history: [History]?

    enum CodingKeys: String, CodingKey {
        case created, author, architecture, os, variant, config, rootfs, history
        case osVersion = "os.version"
    }

    public init(
        created: String? = nil, author: String? = nil, architecture: String? = nil, os: String? = nil, variant: String? = nil,
        config: Config? = nil, rootfs: RootFS? = nil, history: [History]? = nil
    ) {
        self.created = created
        self.author = author
        self.architecture = architecture
        self.os = os
        self.variant = variant
        self.config = config
        self.rootfs = rootfs
        self.history = history
    }

    /// `created` as a date. Images write RFC 3339 with or without fractional seconds.
    public var createdDate: Date? {
        created.flatMap(Self.parseTime)
    }

    static func parseTime(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

/// An OCI descriptor in Docker's field names, as `Descriptor` in image lists and inspects.
public struct DockerDescriptor: Codable, Sendable, Equatable, Hashable {
    public var mediaType: String
    public var digest: String
    public var size: Int64

    public init(mediaType: String, digest: String, size: Int64) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
    }
}

/// One entry of an image's index: a platform's manifest, an attestation, or something else.
public struct EngineImageManifest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case image
        case attestation
        case unknown
    }

    public var descriptor: DockerDescriptor
    public var kind: Kind
    /// `os/arch[/variant]` for an image manifest.
    public var platform: (os: String, architecture: String, variant: String?)?
    /// Whether its content is here. A pull for one platform leaves the others out.
    public var available: Bool
    /// The manifest, its config and its layers, compressed, as far as they are here.
    public var contentSize: Int64
    /// For an attestation, the digest of the manifest it attests.
    public var attestationFor: String?

    public init(
        descriptor: DockerDescriptor, kind: Kind, platform: (os: String, architecture: String, variant: String?)?, available: Bool,
        contentSize: Int64, attestationFor: String? = nil
    ) {
        self.descriptor = descriptor
        self.kind = kind
        self.platform = platform
        self.available = available
        self.contentSize = contentSize
        self.attestationFor = attestationFor
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.descriptor == rhs.descriptor && lhs.kind == rhs.kind && lhs.platform?.os == rhs.platform?.os
            && lhs.platform?.architecture == rhs.platform?.architecture && lhs.platform?.variant == rhs.platform?.variant
            && lhs.available == rhs.available && lhs.contentSize == rhs.contentSize && lhs.attestationFor == rhs.attestationFor
    }
}

/// One reference the engine keeps, with what the image it names says about itself.
///
/// The engine keeps images by reference; Docker keeps them by ID with any number of
/// references. Records with the same `id` are one Docker image.
public struct EngineImageRecord: Sendable, Equatable {
    /// The reference as the engine keeps it: `docker.io/library/alpine:latest`.
    public var reference: String
    /// The index or manifest the reference names.
    public var target: DockerDescriptor
    /// The image's ID: the digest of its config for the host's platform, or for the first
    /// platform it has content for, or the target's digest when it has none.
    public var id: String
    /// The host platform's manifest, config and layers, compressed.
    public var size: Int64
    public var config: DockerImageConfigDocument?
    /// The compressed size of each layer of the manifest `id` comes from, in order.
    public var layerSizes: [Int64]
    public var manifests: [EngineImageManifest]
    /// The manifest `id` and `size` come from, which a container made from it runs.
    public var manifestDigest: String?
    /// The engine's own images (the init and builder images), which a Docker client never sees.
    public var infrastructure: Bool

    public init(
        reference: String, target: DockerDescriptor, id: String, size: Int64, config: DockerImageConfigDocument?,
        layerSizes: [Int64] = [], manifests: [EngineImageManifest] = [], manifestDigest: String? = nil, infrastructure: Bool = false
    ) {
        self.reference = reference
        self.target = target
        self.id = id
        self.size = size
        self.config = config
        self.layerSizes = layerSizes
        self.manifests = manifests
        self.manifestDigest = manifestDigest
        self.infrastructure = infrastructure
    }

    /// The reference parsed, or nil for one Docker's grammar does not accept.
    public var parsed: DockerImageReference? {
        try? DockerImageReference(reference, defaultTag: false)
    }

    /// The reference as Docker prints it.
    public var familiarReference: String {
        parsed?.familiar ?? reference
    }

    /// Whether it names a tag; a reference by digest alone does not.
    public var isTagged: Bool {
        parsed?.tag != nil
    }
}

/// A Docker image: the engine's references that share an ID.
public struct DockerImage: Sendable, Equatable {
    public let id: String
    /// Sorted by reference.
    public let records: [EngineImageRecord]

    init(id: String, records: [EngineImageRecord]) {
        self.id = id
        self.records = records.sorted { $0.reference < $1.reference }
    }

    /// The record the image's own fields come from: a tagged one when there is one.
    public var primary: EngineImageRecord {
        records.first(where: \.isTagged) ?? records[0]
    }

    public var config: DockerImageConfigDocument? { primary.config }

    public var created: Date? { config?.createdDate }

    public var labels: [String: String] { config?.config?.Labels ?? [:] }

    /// `alpine:latest`, one per tagged reference.
    public var repoTags: [String] {
        Self.unique(records.filter(\.isTagged).map(\.familiarReference))
    }

    /// `alpine@sha256:…`, one per repository and target, as the containerd image store
    /// reports a pulled image.
    public var repoDigests: [String] {
        Self.unique(
            records.map { record in
                let name = record.parsed?.familiarName ?? record.familiarReference
                return "\(name)@\(record.target.digest)"
            })
    }

    /// No tag names it: what `dangling=true` lists and a plain prune removes.
    public var isDangling: Bool {
        !records.contains(where: \.isTagged)
    }

    /// The hex of the ID, without the algorithm.
    public var hexID: String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    /// The ID as Docker shortens it in messages: 12 hex characters.
    public var shortID: String {
        String(hexID.prefix(12))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// The engine's images as a Docker client sees them: grouped by ID, without the engine's own.
public struct DockerImageCatalog: Sendable {
    /// Newest first.
    public let images: [DockerImage]

    public init(_ records: [EngineImageRecord]) {
        let grouped = Dictionary(grouping: records.filter { !$0.infrastructure }, by: \.id)
        images = grouped.map { DockerImage(id: $0.key, records: $0.value) }.sorted { lhs, rhs in
            let left = lhs.created ?? .distantPast
            let right = rhs.created ?? .distantPast
            return left != right ? left > right : lhs.id < rhs.id
        }
    }

    /// What a name in a request resolved to: the image, and the reference that named it, or nil
    /// when it was named by ID.
    public struct Match: Sendable {
        public let image: DockerImage
        public let record: EngineImageRecord?
    }

    /// Finds the image `term` names, as dockerd looks one up: a full ID (or a target digest), a
    /// reference (`alpine` is `alpine:latest`; `name@digest` matches the reference by digest or
    /// one whose target has that digest), then a unique prefix of an ID's hex.
    public func resolve(_ term: String) throws(DockerAPIError) -> Match {
        let term = term.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { throw .badRequest("image name cannot be blank") }
        if term.wholeMatch(of: #/sha256:[0-9a-f]{64}/#) != nil {
            if let image = images.first(where: { $0.id == term || $0.records.contains { $0.target.digest == term } }) {
                return Match(image: image, record: nil)
            }
            throw .notFound("No such image: \(term)")
        }
        var parsed: DockerImageReference?
        if let reference = try? DockerImageReference(term) {
            parsed = reference
            if let match = find(reference) { return match }
        }
        if term.wholeMatch(of: #/[0-9a-f]{1,64}/#) != nil {
            let candidates = images.filter { $0.hexID.hasPrefix(term) }
            if candidates.count == 1 { return Match(image: candidates[0], record: nil) }
            if candidates.count > 1 { throw .badRequest("multiple IDs found with provided prefix: \(term)") }
        }
        throw .notFound("No such image: \(parsed?.familiar ?? term)")
    }

    func find(_ reference: DockerImageReference) -> Match? {
        for image in images {
            for record in image.records {
                if record.reference == reference.normalized || record.parsed == reference {
                    return Match(image: image, record: record)
                }
                guard let digest = reference.digest, let recorded = record.parsed, recorded.name == reference.name else { continue }
                if recorded.digest == digest || record.target.digest == digest {
                    return Match(image: image, record: record)
                }
            }
        }
        return nil
    }

    /// The containers made from `image`: by the ID this service recorded at create, or by the
    /// index the engine recorded, or by the reference, which is all a container made with
    /// `container run` carries.
    public static func containers(using image: DockerImage, among containers: [DockerContainer]) -> [DockerContainer] {
        let targets = Set(image.records.map(\.target.digest))
        let references = Set(image.records.map(\.reference))
        return containers.filter { container in
            let description = container.snapshot.configuration.image
            return ContainerViewMapper.imageID(container) == image.id || targets.contains(description.digest)
                || references.contains(description.reference)
        }
    }
}
