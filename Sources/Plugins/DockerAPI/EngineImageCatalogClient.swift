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
import DockerAPIEngine
import DockerAPIService
import Foundation
import TerminalProgress

/// The image routes' engine beyond pull: the images service, through the client the
/// `container image` commands use.
extension EngineImagesClient {
    func list() async throws -> [EngineImageRecord] {
        try await EngineErrors.translated {
            let system = try await EngineContainersClient.systemConfig()
            return try await EngineImageRecords.list(builderImage: system.build.image, initImage: system.vminit.image)
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
                platform: platform, scheme: try RequestScheme(DockerRegistryAuth.scheme(forReference: image.reference)), containerSystemConfig: system,
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
        try await EngineImageRecords.imageIDs()
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
