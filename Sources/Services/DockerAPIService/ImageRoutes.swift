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
    func pull(reference: String, platform: String?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws -> DockerPulledImage
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

/// The image routes `docker run` needs: pull.
public enum ImageRoutes {
    /// - Parameter progressInterval: the least time between two progress lines.
    public static func register(on router: inout DockerRouter, engine: some EngineImages, progressInterval: Duration = .milliseconds(100)) {
        router.add(.POST, "/images/create") { request, _ in try pull(request, engine: engine, progressInterval: progressInterval) }
    }

    /// `POST /images/create?fromImage=&tag=&platform=`: Docker's JSON progress stream.
    ///
    /// Everything that can be refused is refused before the head, as a status the CLI shows.
    /// After the head, a failure is the stream's last line, `{"errorDetail":…,"error":…}`,
    /// which is how the CLI expects a failed pull.
    static func pull(_ request: DockerRequest, engine: some EngineImages, progressInterval: Duration) throws(DockerAPIError) -> DockerResponse {
        if let source = request.query("fromSrc"), !source.isEmpty {
            throw .notImplemented("importing an image is not supported by SiliconShip: load an image archive with docker load instead")
        }
        guard let fromImage = request.query("fromImage"), !fromImage.isEmpty else {
            throw .badRequest("fromImage is required to pull an image")
        }
        let reference = try DockerPullReference(fromImage: fromImage, tag: request.query("tag"))
        let platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
        if let platform, platform.wholeMatch(of: #/[a-z0-9_.-]+\/[a-z0-9_.-]+(?:\/[a-z0-9_.-]+)?/#) == nil {
            throw .badRequest("invalid platform \(platform): expected os/arch[/variant]")
        }
        // TODO(#229): X-Registry-Auth is the client's one-shot registry credential. Stage A's
        // decision (2026-10-15) passes it to the images service as a one-shot credential that is
        // neither stored nor logged; until that route takes one, it is accepted here and not
        // used, and pulls use the logins the engine keeps. It must never be logged.
        _ = request.headers["X-Registry-Auth"]

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
                return try await engine.pull(reference: reference.reference, platform: platform) { events in
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
            try await writer.writeJSON(DockerProgressMessage(status: "Pull complete", id: id))
            try await writer.writeJSON(DockerProgressMessage(status: "Digest: \(result.digest)"))
            let status = result.updated ? "Downloaded newer image for" : "Image is up to date for"
            try await writer.writeJSON(DockerProgressMessage(status: "Status: \(status) \(reference.familiar)"))
        }
    }
}
