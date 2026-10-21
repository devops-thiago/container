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
import DockerAPIService

/// The engine's images as the Docker views read them, through the client the `container image`
/// commands use: what the Docker API agent serves and what `container inspect --type image`
/// prints.
public enum EngineImageRecords {
    /// Every image, the engine's own (its builder and init images) marked as such.
    public static func list(builderImage: String, initImage: String) async throws -> [EngineImageRecord] {
        var records: [EngineImageRecord] = []
        for image in try await ClientImage.list() {
            var record = try await ImageRecordCache.shared.record(for: image)
            record.infrastructure = Utility.isInfraImage(name: image.reference, builderImage: builderImage, initImage: initImage)
            records.append(record)
        }
        return records
    }

    /// Image ID by index digest, for the containers the engine made without the Docker API:
    /// of every image, or of those whose index digest is in `digests`.
    public static func imageIDs(digests: Set<String>? = nil) async throws -> [String: String] {
        var ids: [String: String] = [:]
        for image in try await ClientImage.list() where digests?.contains(image.digest) ?? true {
            ids[image.digest] = try await ImageRecordCache.shared.record(for: image).id
        }
        return ids
    }
}
