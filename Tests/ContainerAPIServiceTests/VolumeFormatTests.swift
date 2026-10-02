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

import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIService

/// A volume is mounted where an image expects a directory nobody has written to.
struct VolumeFormatTests {
    private func temporaryImage() throws -> (directory: URL, image: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("volume-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("volume.img").path)
    }

    @Test("a new volume has nothing in it, lost+found included")
    func empty() throws {
        let (directory, image) = try temporaryImage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try VolumesService.formatVolumeImage(at: image, sizeInBytes: 64 * 1024 * 1024)

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image))
        #expect(try reader.listDirectory(FilePath("/")).isEmpty)
        #expect(!reader.exists(FilePath("/lost+found")))
    }

    @Test("a journaled volume is as empty")
    func emptyWithAJournal() throws {
        let (directory, image) = try temporaryImage()
        defer { try? FileManager.default.removeItem(at: directory) }

        try VolumesService.formatVolumeImage(
            at: image, sizeInBytes: 64 * 1024 * 1024, journal: EXT4.JournalConfig(size: nil, defaultMode: .ordered))

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image))
        #expect(try reader.listDirectory(FilePath("/")).isEmpty)
    }
}
