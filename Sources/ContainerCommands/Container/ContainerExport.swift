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

import ArgumentParser
import ContainerAPIClient
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    public struct ContainerExport: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "export",
                abstract: "Export a container's filesystem as a tar archive",
            )
        }

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(
            name: .shortAndLong, help: "Pathname for the saved container filesystem (defaults to stdout)", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        var output: String?

        @Flag(name: .shortAndLong, help: "Replace an existing output file")
        var force: Bool = false

        @Argument(help: "container ID")
        var id: String

        public func run() async throws {
            let client = ContainerClient()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let archive = tempDir.appendingPathComponent("archive.tar")
            try await client.export(id: id, archive: archive)

            if output == nil {
                guard let fileHandle = try? FileHandle(forReadingFrom: archive) else {
                    throw ContainerizationError(.internalError, message: "unable to open archive for reading")
                }
                let bufferSize = 4096
                while true {
                    let chunk = fileHandle.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    FileHandle.standardOutput.write(chunk)
                }
                try fileHandle.close()
            } else {
                let outputURL = URL(fileURLWithPath: output!)
                try ExportDestination.commit(archive: archive, to: outputURL, force: force)
            }
        }
    }
}

/// Where an exported archive ends up, and how it gets there without taking anything with it.
///
/// The output path used to be removed — recursively, whatever it was — before the archive was
/// moved in, so a directory named by mistake was gone, and a move that then failed left neither
/// the original nor the export. An existing destination is now refused unless `--force` says
/// otherwise; a forced replacement stages the archive beside the destination and renames it
/// over in one step, so the previous file survives every failure before that step; and a
/// directory or a symlink is never replaced at all, forced or not.
public enum ExportDestination {
    public static func commit(
        archive: URL,
        to output: URL,
        force: Bool,
        rename: (String, String) -> Int32 = { Darwin.rename($0, $1) }
    ) throws {
        let path = output.path(percentEncoded: false)
        var existing = stat()
        let exists = lstat(path, &existing) == 0
        if exists {
            let kind = existing.st_mode & S_IFMT
            guard kind == S_IFREG else {
                let what = kind == S_IFDIR ? "a directory" : kind == S_IFLNK ? "a symbolic link" : "not a regular file"
                throw ContainerizationError(
                    .invalidArgument,
                    message: "refusing to replace \(path): it is \(what); export to a file path instead")
            }
            guard force else {
                throw ContainerizationError(.exists, message: "\(path) exists; pass --force to replace it")
            }
        }

        // Staged beside the destination so the final step is a rename on the same volume.
        let staged = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: archive, to: staged)
        } catch {
            throw ContainerizationError(.internalError, message: "export failed: could not stage the archive next to \(path)", cause: error)
        }
        guard rename(staged.path(percentEncoded: false), path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw ContainerizationError(
                .internalError,
                message: exists
                    ? "could not replace \(path): \(reason); the previous file was kept"
                    : "could not put the export at \(path): \(reason)")
        }
    }
}
