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

import Foundation
import NIOHTTP1
import Synchronization

/// The engine's images as the image routes see them. The agent answers it from the images
/// service; tests answer it from a fake.
public protocol EngineImages: Sendable {
    /// Pulls `reference` for `platform` (the host's when nil) and unpacks it, reporting progress
    /// as it goes. A failure a client should see in words throws a `DockerAPIError`.
    ///
    /// With `credential`, the registry is signed in to with it, for this pull only, instead of
    /// with a login the engine keeps.
    func pull(
        reference: String, platform: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void
    ) async throws -> DockerPulledImage
    /// Every reference the engine keeps, the engine's own images marked as such.
    func list() async throws -> [EngineImageRecord]
    /// Makes `target` name what the engine reference `source` names. `target` is in Docker's
    /// normal form (`docker.io/library/alpine:latest`).
    func tag(_ source: String, as target: String) async throws
    /// Deletes one engine reference. The content stays until `collectGarbage`.
    func delete(_ reference: String) async throws
    /// Removes the content no reference needs any more, as `container image delete` does after
    /// a delete. Returns the bytes freed.
    func collectGarbage() async throws -> UInt64
    /// Pushes the engine reference to its registry, for `platform` or every platform it has.
    /// Returns what the registry now has under the tag when that is the index as kept here;
    /// nil when only some platforms went, which the engine pushes as an index of its own.
    ///
    /// With `credential`, the registry is signed in to with it, for this push only.
    func push(
        reference: String, platform: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void
    ) async throws -> DockerDescriptor?
    /// Writes the engine references, for `platform` (the host's when nil), as one archive at `file`.
    func save(references: [String], platform: String?, to file: URL) async throws
    /// Loads the archive at `file` and unpacks it for the host.
    func load(from file: URL) async throws -> DockerLoadedImages
}

/// What a load left in place.
public struct DockerLoadedImages: Sendable, Equatable {
    /// The engine references the archive made.
    public var references: [String]
    /// Archive members that were not extracted (unsafe paths or links).
    public var rejectedMembers: [String]

    public init(references: [String], rejectedMembers: [String] = []) {
        self.references = references
        self.rejectedMembers = rejectedMembers
    }
}

/// An image a pull left in place.
public struct DockerPulledImage: Sendable, Equatable {
    /// The digest the reference resolved to.
    public let digest: String
    /// Whether the pull changed what the reference names here: false when it was already up
    /// to date.
    public let updated: Bool

    public init(digest: String, updated: Bool) {
        self.digest = digest
        self.updated = updated
    }
}

/// The image routes: pull, and with the engine's containers at hand, everything else.
public enum ImageRoutes {
    /// - Parameters:
    ///   - progressInterval: the least time between two progress lines.
    ///   - events: where a pull is reported once it is done; nil reports nothing.
    public static func register(
        on router: inout DockerRouter, engine: some EngineImages, progressInterval: Duration = .milliseconds(100), events: DockerEventBus? = nil
    ) {
        router.add(.POST, "/images/create") { request, _ in try pull(request, engine: engine, progressInterval: progressInterval, events: events) }
    }

    static func validate(platform: String?) throws(DockerAPIError) {
        if let platform, platform.wholeMatch(of: #/[a-z0-9_.-]+\/[a-z0-9_.-]+(?:\/[a-z0-9_.-]+)?/#) == nil {
            throw .badRequest("invalid platform \(platform): expected os/arch[/variant]")
        }
    }

    /// `POST /images/create?fromImage=&tag=&platform=`: Docker's JSON progress stream.
    ///
    /// Everything that can be refused is refused before the head, as a status the CLI shows.
    /// After the head, a failure is the stream's last line, `{"errorDetail":…,"error":…}`,
    /// which is how the CLI expects a failed pull.
    static func pull(
        _ request: DockerRequest, engine: some EngineImages, progressInterval: Duration, events: DockerEventBus? = nil
    ) throws(DockerAPIError) -> DockerResponse {
        if let source = request.query("fromSrc"), !source.isEmpty {
            throw .notImplemented("importing an image is not supported by SiliconShip: load an image archive with docker load instead")
        }
        guard let fromImage = request.query("fromImage"), !fromImage.isEmpty else {
            throw .badRequest("fromImage is required to pull an image")
        }
        let reference = try DockerPullReference(fromImage: fromImage, tag: request.query("tag"))
        let platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
        try validate(platform: platform)
        // The client's credential for this pull, passed to the images service for it alone:
        // neither kept nor logged. Without one, the engine's own logins are used.
        let credential = DockerRegistryAuth.credential(header: request.headers.first(name: DockerRegistryAuth.header))

        return .stream(status: .ok, contentType: "application/json") { writer in
            let id =
                reference.tagOrDigest.count > 12 && reference.tagOrDigest.contains(":")
                ? String(reference.tagOrDigest.split(separator: ":").last?.prefix(12) ?? "") : reference.tagOrDigest
            try await writer.writeJSON(DockerProgressMessage(status: "Pulling from \(reference.repository)", id: id))

            // The engine reports from tasks of its own, in any order and possibly after the
            // pull returned: the sums are kept here and only the latest is written.
            let (updates, continuation) = AsyncStream.makeStream(of: DockerPullProgress.self, bufferingPolicy: .bufferingNewest(1))
            let state = Mutex(DockerPullProgress())
            let pulling = Task {
                defer { continuation.finish() }
                return try await engine.pull(reference: reference.reference, platform: platform, credential: credential) { events in
                    let progress = state.withLock { progress in
                        progress.apply(events)
                        return progress
                    }
                    continuation.yield(progress)
                }
            }
            let result: DockerPulledImage
            do {
                try await withTaskCancellationHandler {
                    for await progress in updates {
                        try await writer.writeJSON(progress.message(id: id))
                        try await Task.sleep(for: progressInterval)
                    }
                } onCancel: {
                    pulling.cancel()
                }
                result = try await pulling.value
            } catch is CancellationError {
                pulling.cancel()
                throw CancellationError()
            } catch {
                pulling.cancel()
                try await writer.writeJSON(DockerProgressMessage.failure((error as? DockerAPIError)?.message ?? "\(error)"))
                return
            }
            // As dockerd reports a pull: by the reference as the client knows it.
            await events?.publish(type: "image", action: "pull", actorID: reference.familiar, attributes: ["name": DockerEventFilter.stripTag(reference.familiar)])
            try await writer.writeJSON(DockerProgressMessage(status: "Pull complete", id: id))
            try await writer.writeJSON(DockerProgressMessage(status: "Digest: \(result.digest)"))
            let status = result.updated ? "Downloaded newer image for" : "Image is up to date for"
            try await writer.writeJSON(DockerProgressMessage(status: "Status: \(status) \(reference.familiar)"))
        }
    }
}
