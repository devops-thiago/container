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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerCommands

/// `container export -o` must never take an existing path with it.
struct ExportDestinationTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func archive(in dir: URL, _ content: String = "archive bytes") throws -> URL {
        let file = dir.appendingPathComponent("archive.tar")
        try Data(content.utf8).write(to: file)
        return file
    }

    private func leftovers(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
    }

    @Test("a new output path is written")
    func newOutput() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try ExportDestination.commit(archive: try archive(in: dir), to: out, force: false)
        #expect(try Data(contentsOf: out) == Data("archive bytes".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("an existing regular file is refused without --force and left untouched")
    func existingFileRefused() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(archive: try archive(in: dir), to: out, force: false)
        }
        #expect(error?.code == .exists)
        #expect(error?.message.contains("--force") == true)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
    }

    @Test("a non-empty directory is refused, forced or not, and nothing inside it is touched")
    func directoryRefused() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: out.appendingPathComponent("important.txt"))
        for force in [false, true] {
            let error = #expect(throws: ContainerizationError.self) {
                try ExportDestination.commit(archive: try archive(in: dir), to: out, force: force)
            }
            #expect(error?.message.contains("directory") == true)
        }
        #expect(try Data(contentsOf: out.appendingPathComponent("important.txt")) == Data("keep me".utf8))
    }

    @Test("a symlink is refused, and its target is not replaced")
    func symlinkRefused() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("elsewhere.tar")
        try Data("target".utf8).write(to: target)
        let link = dir.appendingPathComponent("rootfs.tar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(archive: try archive(in: dir), to: link, force: true)
        }
        #expect(error?.message.contains("symbolic link") == true)
        #expect(try Data(contentsOf: target) == Data("target".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test("--force replaces a regular file in one step")
    func forcedReplacement() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        try ExportDestination.commit(archive: try archive(in: dir, "replacement"), to: out, force: true)
        #expect(try Data(contentsOf: out) == Data("replacement".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a failure at the final step keeps the previous file and names the path")
    func finalMoveFailureKeepsPrevious() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(archive: try archive(in: dir, "replacement"), to: out, force: true) { _, _ in
                errno = EIO
                return -1
            }
        }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains("previous file was kept") == true)
        #expect(error?.message.contains(out.path) == true)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
        #expect(try leftovers(in: dir).isEmpty, "the staged archive is removed")
    }
}
