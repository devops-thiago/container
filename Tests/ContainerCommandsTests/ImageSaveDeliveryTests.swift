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
import Darwin
import Foundation
import Testing

@testable import ContainerCommands

struct ImageSaveDeliveryTests {
    private func withFiles(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.tar")
        try Data("new archive".utf8).write(to: staged)
        try body(root, staged, root.appendingPathComponent("output.tar"))
    }

    @Test("image save refuses nonempty directories without deleting children")
    func directoryPreserved() throws {
        try withFiles { _, staged, output in
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let child = output.appendingPathComponent("important")
            try Data("keep".utf8).write(to: child)
            #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output) }
            #expect(try Data(contentsOf: child) == Data("keep".utf8))
        }
    }

    @Test("image save refuses links and FIFOs", arguments: ["link", "dangling", "fifo"])
    func nonRegularPreserved(kind: String) throws {
        try withFiles { root, staged, output in
            let target = root.appendingPathComponent("target")
            if kind == "fifo" {
                #expect(mkfifo(output.path, 0o600) == 0)
            } else {
                if kind == "link" { try Data("keep".utf8).write(to: target) }
                try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
            }
            var before = stat()
            #expect(lstat(output.path, &before) == 0)
            #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output) }
            var after = stat()
            #expect(lstat(output.path, &after) == 0)
            #expect(after.st_ino == before.st_ino)
            if kind == "link" { #expect(try Data(contentsOf: target) == Data("keep".utf8)) }
        }
    }

    @Test("missing staging input preserves the previous archive")
    func missingStagePreservesPrevious() throws {
        try withFiles { _, staged, output in
            try Data("previous".utf8).write(to: output)
            try FileManager.default.removeItem(at: staged)
            #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output) }
            #expect(try Data(contentsOf: output) == Data("previous".utf8))
        }
    }

    @Test("save rejects invalid staging inputs", arguments: ["directory", "link", "fifo"])
    func invalidStage(kind: String) throws {
        try withFiles { _, staged, output in
            try Data("previous".utf8).write(to: output)
            try FileManager.default.removeItem(at: staged)
            switch kind {
            case "directory": try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            case "link": try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: output)
            default: #expect(mkfifo(staged.path, 0o600) == 0)
            }
            #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output) }
            #expect(try Data(contentsOf: output) == Data("previous".utf8))
        }
    }

    @Test("staging and precommit failures retain the previous bytes", arguments: [EACCES, ENOSPC, EIO])
    func failuresPreservePrevious(code: Int32) throws {
        for stageFailure in [true, false] {
            try withFiles { _, staged, output in
                try Data("previous".utf8).write(to: output)
                var operations = ExportDestination.Operations()
                if stageFailure {
                    operations.stage = { _, _, _ in throw POSIXError(POSIXErrorCode(rawValue: code)!) }
                } else {
                    operations.rename = { _, _, _, _, _ in
                        errno = code
                        return -1
                    }
                }
                #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output, operations: operations) }
                #expect(try Data(contentsOf: output) == Data("previous".utf8))
            }
        }
    }

    @Test("same-volume and forced cross-volume delivery preserve the archive", arguments: [false, true])
    func successfulDelivery(forceCopy: Bool) throws {
        for replacing in [false, true] {
            try withFiles { _, staged, output in
                if replacing { try Data("previous".utf8).write(to: output) }
                var operations = ExportDestination.Operations()
                operations.stage = { archive, directory, name in
                    try ExportDestination.stageArchive(archive, in: directory, named: name, forceCopy: forceCopy)
                }
                try Application.ImageSave.deliver(staged, to: output, operations: operations)
                #expect(try Data(contentsOf: output) == Data("new archive".utf8))
            }
        }
    }

    @Test("non-regular destination swaps survive commit", arguments: ["directory", "link", "fifo"])
    func destinationSwap(kind: String) throws {
        try withFiles { root, staged, output in
            try Data("previous".utf8).write(to: output)
            let target = root.appendingPathComponent("target")
            try Data("keep".utf8).write(to: target)
            var operations = ExportDestination.Operations()
            operations.rename = { fromDirectory, from, toDirectory, to, flags in
                #expect(unlinkat(toDirectory, to, 0) == 0)
                switch kind {
                case "directory":
                    #expect(mkdirat(toDirectory, to, 0o700) == 0)
                    try! Data("child".utf8).write(to: output.appendingPathComponent("child"))
                case "link": #expect(symlinkat(target.path, toDirectory, to) == 0)
                default: #expect(mkfifo(output.path, 0o600) == 0)
                }
                return renameatx_np(fromDirectory, from, toDirectory, to, flags)
            }
            #expect(throws: (any Error).self) { try Application.ImageSave.deliver(staged, to: output, operations: operations) }
            var info = stat()
            #expect(lstat(output.path, &info) == 0)
            #expect(info.st_mode & S_IFMT == (kind == "directory" ? S_IFDIR : kind == "link" ? S_IFLNK : S_IFIFO))
            #expect(try Data(contentsOf: target) == Data("keep".utf8))
            if kind == "directory" { #expect(try Data(contentsOf: output.appendingPathComponent("child")) == Data("child".utf8)) }
        }
    }
}

extension ImageSaveDeliveryTests {
    /// The release qualifier supplies a real OCI archive and an empty run-owned directory,
    /// then loads both outputs through the signed CLI. This exercises the streaming fallback
    /// deterministically without requiring a second mounted volume on every development host.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARCHIVE_DELIVERY_INPUT"] != nil))
    func releaseArchiveDelivery() throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(environment["ARCHIVE_DELIVERY_INPUT"]))
        let root = URL(fileURLWithPath: try #require(environment["ARCHIVE_DELIVERY_OUTPUT"]))
        let expectedSize = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber
        for forceCopy in [false, true] {
            let name = forceCopy ? "forced-copy" : "same-volume"
            let staged = root.appendingPathComponent("\(name)-staged.tar")
            let output = root.appendingPathComponent("\(name).tar")
            try FileManager.default.copyItem(at: input, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            try Data("previous archive".utf8).write(to: output, options: .withoutOverwriting)
            var operations = ExportDestination.Operations()
            operations.stage = { archive, directory, name in
                try ExportDestination.stageArchive(archive, in: directory, named: name, forceCopy: forceCopy)
            }
            try Application.ImageSave.deliver(staged, to: output, operations: operations)
            #expect(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber == expectedSize)
        }
    }
}
