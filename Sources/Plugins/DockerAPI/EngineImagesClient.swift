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
import ContainerizationError
import ContainerizationOCI
import DockerAPIService
import TerminalProgress

/// The image routes' engine: the images service, through the client `container image pull`
/// uses. A pull is for one platform, the host's unless the client names one, and leaves the
/// image unpacked for it, so the create that follows finds it ready.
struct EngineImagesClient: EngineImages {
    func pull(
        reference: String, platform requested: String?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void
    ) async throws -> DockerPulledImage {
        let platform: ContainerizationOCI.Platform
        do {
            platform = try requested.map(Parser.platform(from:)) ?? Parser.platform(os: "linux", arch: Arch.hostArchitecture().rawValue)
        } catch {
            throw DockerAPIError.badRequest("invalid platform \(requested ?? ""): \(error)")
        }
        do {
            let system = try await EngineContainersClient.systemConfig()
            let before = try? await ClientImage.get(reference: reference, containerSystemConfig: system).digest
            let image = try await ClientImage.pull(
                reference: reference, platform: platform, containerSystemConfig: system,
                progressUpdate: { events in progress(events.compactMap(Self.event)) })
            progress([.extracting])
            _ = try await image.getCreateSnapshot(platform: platform)
            return DockerPulledImage(digest: image.digest, updated: image.digest != before)
        } catch let error as ContainerizationError {
            // Said in words, as the CLI prints the last line of a failed pull.
            let cause = error.cause.map { ": \($0)" } ?? ""
            throw DockerAPIError(error.isCode(.notFound) ? .notFound : .internalServerError, error.message + cause)
        }
    }

    static func event(_ event: ProgressUpdateEvent) -> DockerPullEvent? {
        switch event {
        case .addItems(let count): .addItems(count)
        case .addTotalItems(let count): .addTotalItems(count)
        case .addSize(let bytes): .addSize(bytes)
        case .addTotalSize(let bytes): .addTotalSize(bytes)
        default: nil
        }
    }
}
