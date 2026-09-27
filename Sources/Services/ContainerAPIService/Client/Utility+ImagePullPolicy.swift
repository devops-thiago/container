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

import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import TerminalProgress

extension Utility {
    /// The same request reaches pull and fetch; a policy must not discard the registry
    /// scheme, platform, progress callback or download concurrency limit.
    struct ImageRequest: Sendable {
        let reference: String
        let platform: Platform
        let scheme: RequestScheme
        let config: ContainerSystemConfig
        let progress: ProgressUpdateHandler
        let maxConcurrentDownloads: Int
    }

    /// The image operations used by create, injectable without contacting a daemon or registry.
    struct ImageClient: Sendable {
        var pull: @Sendable (ImageRequest) async throws -> ClientImage
        var fetch: @Sendable (ImageRequest) async throws -> ClientImage
        var get: @Sendable (String, ContainerSystemConfig) async throws -> ClientImage

        static let live = Self(
            pull: { request in
                try await ClientImage.pull(
                    reference: request.reference, platform: request.platform, scheme: request.scheme,
                    containerSystemConfig: request.config, progressUpdate: request.progress,
                    maxConcurrentDownloads: request.maxConcurrentDownloads)
            },
            fetch: { request in
                try await ClientImage.fetch(
                    reference: request.reference, platform: request.platform, scheme: request.scheme,
                    containerSystemConfig: request.config, progressUpdate: request.progress,
                    maxConcurrentDownloads: request.maxConcurrentDownloads)
            },
            get: { try await ClientImage.get(reference: $0, containerSystemConfig: $1) })
    }

    static func imageForCreate(
        policy: Flags.ImageFetch.PullPolicy, request: ImageRequest, client: ImageClient = .live
    ) async throws -> ClientImage {
        switch policy {
        case .always:
            return try await client.pull(request)
        case .missing:
            return try await client.fetch(request)
        case .never:
            do {
                return try await client.get(request.reference, request.config)
            } catch let error as ContainerizationError where error.isCode(.notFound) {
                throw ContainerizationError(
                    .notFound,
                    message: "image \(request.reference) is not available locally and --pull never forbids fetching it")
            }
        }
    }
}
