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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import DockerAPIService
import Foundation
import Synchronization
import TerminalProgress

/// The image routes' engine beyond pull: the images service, through the client the
/// `container image` commands use.
extension EngineImagesClient {
    func list() async throws -> [EngineImageRecord] {
        try await EngineErrors.translated {
            let system = try await EngineContainersClient.systemConfig()
            var records: [EngineImageRecord] = []
            for image in try await ClientImage.list() {
                var record = try await ImageRecordCache.shared.record(for: image)
                record.infrastructure = Utility.isInfraImage(
                    name: image.reference, builderImage: system.build.image, initImage: system.vminit.image)
                records.append(record)
            }
            return records
        }
    }

    /// The engine image whose reference is exactly `reference`.
    private static func image(_ reference: String) async throws -> ClientImage {
        guard let image = try await ClientImage.list().first(where: { $0.reference == reference }) else {
            throw DockerAPIError.notFound("No such image: \(reference)")
        }
        return image
    }

    func tag(_ source: String, as target: String) async throws {
        try await EngineErrors.translated {
            let system = try await EngineContainersClient.systemConfig()
            try await Self.image(source).tag(new: try ClientImage.normalizeReference(target, containerSystemConfig: system))
        }
    }

    func delete(_ reference: String) async throws {
        try await EngineErrors.translated { try await ClientImage.delete(reference: reference, garbageCollect: false) }
    }

    func collectGarbage() async throws -> UInt64 {
        try await EngineErrors.translated { try await ClientImage.cleanUpOrphanedBlobs().1 }
    }

    /// Pushes every platform the image has, unless it lacks some, as a pull for one platform
    /// leaves it: then the host's, which is the one here, rather than failing on what is not.
    ///
    /// The index pushed is the one kept here only when every platform goes; for some, the
    /// engine pushes an index of its own, whose digest it does not report.
    func push(
        reference: String, platform requested: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void
    ) async throws -> DockerDescriptor? {
        var platform = try requested.map(Self.platform)
        return try await EngineErrors.translated {
            let system = try await EngineContainersClient.systemConfig()
            let image = try await Self.image(reference)
            if platform == nil, try await ImageRecordCache.shared.record(for: image).manifests.contains(where: { $0.kind == .image && !$0.available }) {
                platform = ClientImage.hostPlatform
            }
            try await image.push(
                platform: platform, scheme: .https, containerSystemConfig: system,
                progressUpdate: { events in progress(events.compactMap(Self.event)) }, credential: credential.map(Self.engineCredential))
            guard platform == nil else { return nil }
            return DockerDescriptor(mediaType: image.descriptor.mediaType, digest: image.descriptor.digest, size: image.descriptor.size)
        }
    }

    func save(references: [String], platform requested: String?, to file: URL) async throws {
        let platform = try requested.map(Self.platform) ?? ClientImage.hostPlatform
        try await EngineErrors.translated {
            let system = try await EngineContainersClient.systemConfig()
            // A pulled index lists platforms whose content was never fetched: say which, as
            // `container image save` does, rather than fail inside the images service.
            for reference in references {
                do {
                    _ = try await Self.image(reference).manifest(for: platform)
                } catch let error as ContainerizationError where error.isCode(.unsupported) || error.isCode(.notFound) {
                    throw DockerAPIError.notFound("image \(reference) has no content for platform \(platform.description)")
                }
            }
            try await ClientImage.save(references: references, out: file.path(percentEncoded: false), platform: platform, containerSystemConfig: system)
        }
    }

    func load(from file: URL) async throws -> DockerLoadedImages {
        try await EngineErrors.translated {
            let result = try await ClientImage.load(from: file.path(percentEncoded: false), force: false)
            for image in result.images {
                try await image.unpackForHost()
            }
            return DockerLoadedImages(references: result.images.map(\.reference), rejectedMembers: result.rejectedMembers)
        }
    }

    static func platform(_ text: String) throws -> ContainerizationOCI.Platform {
        do {
            return try Parser.platform(from: text)
        } catch {
            throw DockerAPIError.badRequest("invalid platform \(text): \(error)")
        }
    }
}

extension EngineContainersClient {
    /// Image ID by index digest, for the containers the engine made without this service.
    func imageIDs() async throws -> [String: String] {
        var ids: [String: String] = [:]
        for image in try await ClientImage.list() {
            ids[image.digest] = try await ImageRecordCache.shared.record(for: image).id
        }
        return ids
    }
}

/// What the content store says about each image, by the digest its references name. Content
/// is immutable, but which of an index's platforms is here changes with pulls; the cache is
/// dropped whenever the images service reports a change.
final class ImageRecordCache: Sendable {
    static let shared = ImageRecordCache()

    private struct State {
        var generation: String?
        var records: [String: EngineImageRecord] = [:]
    }

    private let state = Mutex(State())

    /// A bound on what is kept: far more images than anyone has, and a reset rather than an
    /// eviction policy past it.
    private static let limit = 4096

    func record(for image: ClientImage) async throws -> EngineImageRecord {
        let generation = try? await ClientImage.state().map { "\($0.processNonce)/\($0.stateGeneration)" }
        let cached = state.withLock { state -> EngineImageRecord? in
            if generation == nil || state.generation != generation || state.records.count > Self.limit {
                state.generation = generation
                state.records = [:]
            }
            return state.records[image.digest]
        }
        if var cached {
            cached.reference = image.reference
            return cached
        }
        let record = try await Self.read(image)
        state.withLock { state in
            if state.generation == generation { state.records[image.digest] = record }
        }
        return record
    }

    /// Reads the image's index, each manifest and the config the ID comes from: the host
    /// platform's, else the first platform whose content is here.
    static func read(_ image: ClientImage) async throws -> EngineImageRecord {
        let descriptor = image.descriptor
        let target = DockerDescriptor(mediaType: descriptor.mediaType, digest: descriptor.digest, size: descriptor.size)
        guard let indexData = try await image.blob(descriptor.digest), let index = try? JSONDecoder().decode(Index.self, from: indexData) else {
            return EngineImageRecord(reference: image.reference, target: target, id: descriptor.digest, size: 0, config: nil)
        }
        let host = ClientImage.hostPlatform
        var manifests: [EngineImageManifest] = []
        var hostChoice: (EngineImageManifest, Manifest)?
        var fallback: (EngineImageManifest, Manifest)?
        for entry in index.manifests {
            let manifest = try await image.blob(entry.digest).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            var configPresent = false
            if let manifest {
                configPresent = try await image.blob(manifest.config.digest) != nil
            }
            let kind: EngineImageManifest.Kind
            if entry.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
                kind = .attestation
            } else if let platform = entry.platform, platform.os != "unknown" {
                kind = .image
            } else {
                kind = .unknown
            }
            let summary = EngineImageManifest(
                descriptor: DockerDescriptor(mediaType: entry.mediaType, digest: entry.digest, size: entry.size),
                kind: kind,
                platform: entry.platform.map { ($0.os, $0.architecture, $0.variant) },
                available: manifest != nil && configPresent,
                contentSize: entry.size + (manifest.map { $0.config.size + $0.layers.reduce(0) { $0 + $1.size } } ?? 0),
                attestationFor: kind == .attestation ? entry.annotations?["vnd.docker.reference.digest"] : nil)
            manifests.append(summary)
            guard kind == .image, summary.available, let manifest else { continue }
            if hostChoice == nil, entry.platform == host { hostChoice = (summary, manifest) }
            if fallback == nil { fallback = (summary, manifest) }
        }
        guard let (chosen, manifest) = hostChoice ?? fallback else {
            return EngineImageRecord(reference: image.reference, target: target, id: descriptor.digest, size: 0, config: nil, manifests: manifests)
        }
        let config = try await image.blob(manifest.config.digest).flatMap { try? JSONDecoder().decode(DockerImageConfigDocument.self, from: $0) }
        return EngineImageRecord(
            reference: image.reference, target: target, id: manifest.config.digest, size: chosen.contentSize, config: config,
            layerSizes: manifest.layers.map(\.size), manifests: manifests, manifestDigest: chosen.descriptor.digest)
    }
}

/// The engine's errors in the HTTP status a Docker client acts on, for the image, volume and
/// network facades.
enum EngineErrors {
    static func translated<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ContainerizationError {
            let cause = error.cause.map { ": \($0)" } ?? ""
            switch error.code {
            case .notFound: throw DockerAPIError.notFound(error.message + cause)
            case .exists, .invalidState: throw DockerAPIError.conflict(error.message + cause)
            case .invalidArgument, .unsupported: throw DockerAPIError.badRequest(error.message + cause)
            default: throw error
            }
        }
    }
}
