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

import ContainerXPC
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import ContainerImagesService

/// The images helper's state generation (#525) moves on every change to what the image list
/// shows, a failed one included: a change can be partly made before it fails.
struct ImageStateGenerationTests {
    private func service() throws -> (ImagesService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-generation-\(UUID().uuidString)")
        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: root.appendingPathComponent("images"), contentStore: contentStore)
        let snapshotStore = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        let service = try ImagesService(
            contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore, log: Logger(label: "ImageStateGenerationTests"))
        return (service, root)
    }

    @Test("a delete and a tag count, the tag even when it fails")
    func mutationsCount() async throws {
        let (service, root) = try service()
        defer { try? FileManager.default.removeItem(at: root) }
        var before = StateGeneration.shared.current
        // Deleting an image that is not there is not an error; it is still counted.
        try await service.delete(reference: "docker.io/library/never-pulled:1", garbageCollect: false)
        #expect(StateGeneration.shared.current > before)
        before = StateGeneration.shared.current
        await #expect(throws: (any Error).self) {
            _ = try await service.tag(old: "docker.io/library/never-pulled:1", new: "docker.io/library/also-never:1")
        }
        #expect(StateGeneration.shared.current > before)
    }
}
