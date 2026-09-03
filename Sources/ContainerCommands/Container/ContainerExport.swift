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
            var needsBestEffortCleanup = true
            defer {
                if needsBestEffortCleanup {
                    try? FileManager.default.removeItem(at: tempDir)
                }
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

            needsBestEffortCleanup = false
            do {
                try FileManager.default.removeItem(at: tempDir)
            } catch {
                let tempPath = tempDir.path(percentEncoded: false)
                let archiveRemains = FileManager.default.fileExists(atPath: archive.path(percentEncoded: false))
                let residue =
                    archiveRemains
                    ? "temporary export data remains at \(tempPath)"
                    : "temporary export data may remain at \(tempPath)"
                throw ContainerizationError(
                    .internalError,
                    message: "the export itself completed, but temporary export cleanup failed; \(residue)",
                    cause: error)
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
/// over in one step. Exclusive Darwin rename flags make the no-force decision authoritative at
/// commit time, while no-follow flags and unlink-only cleanup avoid symlinks and directories.
public enum ExportDestination {
    public typealias Rename = (_ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String, _ flags: UInt32) -> Int32
    public typealias Stage = (_ archive: URL, _ directory: Int32, _ name: String) throws -> Void
    public typealias UnlinkAt = (_ directory: Int32, _ name: String, _ flags: Int32) -> Int32

    public struct Operations {
        public var stage: Stage
        public var rename: Rename
        public var rollback: Rename
        public var unlinkAt: UnlinkAt

        public init() {
            stage = { try ExportDestination.stageArchive($0, in: $1, named: $2) }
            rename = { Darwin.renameatx_np($0, $1, $2, $3, $4) }
            rollback = { Darwin.renameatx_np($0, $1, $2, $3, $4) }
            unlinkAt = { Darwin.unlinkat($0, $1, $2) }
        }
    }

    public static func commit(
        archive: URL,
        to output: URL,
        force: Bool,
        operations: Operations = Operations()
    ) throws {
        let path = output.path(percentEncoded: false)
        let parentPath = output.deletingLastPathComponent().path(percentEncoded: false)
        let name = output.lastPathComponent
        let parent = try openDirectoryWithoutFollowingSymlinks(parentPath, output: path)
        defer { _ = close(parent) }

        var existing = stat()
        let inspection = fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW)
        let exists = inspection == 0
        if inspection != 0, errno != ENOENT {
            throw ContainerizationError(
                .internalError,
                message: "export failed: could not inspect \(path): \(String(cString: strerror(errno)))")
        }
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

        // Stage relative to the already-opened real directory. No textual parent path is
        // resolved after this point, so a symlink swap cannot redirect staging or cleanup.
        let stagedName = ".\(name).\(UUID().uuidString).tmp"
        let stagedPath = output.deletingLastPathComponent().appendingPathComponent(stagedName).path(percentEncoded: false)
        do {
            try operations.stage(archive, parent, stagedName)
        } catch {
            switch cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt) {
            case .clean:
                throw ContainerizationError(
                    .internalError,
                    message: "export failed: could not stage the archive next to \(path)",
                    cause: error)
            case .retained(let cleanupErrno):
                throw ContainerizationError(
                    .internalError,
                    message:
                        "export failed: could not stage the archive next to \(path); cleanup failed: \(String(cString: strerror(cleanupErrno))); a partial staged export remains at \(stagedPath)",
                    cause: error)
            }
        }

        // Force authorizes replacement only of the exact regular-file incarnation observed
        // above. An atomic swap installs the archive without an absent-path window, then the
        // displaced entry is checked by device/inode. If another entry won the race, swap it
        // back before reporting the refusal; neither a symlink nor a replacement regular file
        // is consumed by the export.
        let replacingObservedFile = exists && force
        if replacingObservedFile {
            let flags = UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_SWAP)
            guard operations.rename(parent, stagedName, parent, name, flags) == 0 else {
                let renameErrno = errno
                switch cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt) {
                case .clean:
                    throw ContainerizationError(
                        .internalError,
                        message: "could not replace \(path): \(String(cString: strerror(renameErrno))); the destination was not changed")
                case .retained(let cleanupErrno):
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "could not replace \(path): \(String(cString: strerror(renameErrno))); the destination was not changed, but the staged export could not be cleaned up (\(String(cString: strerror(cleanupErrno)))) and remains at \(stagedPath)"
                    )
                }
            }

            var displaced = stat()
            let displacedInspection = fstatat(parent, stagedName, &displaced, AT_SYMLINK_NOFOLLOW)
            let sameObservedFile =
                displacedInspection == 0
                && displaced.st_mode & S_IFMT == S_IFREG
                && displaced.st_dev == existing.st_dev
                && displaced.st_ino == existing.st_ino
            guard sameObservedFile else {
                let rollbackFlags = UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_SWAP)
                if operations.rollback(parent, name, parent, stagedName, rollbackFlags) == 0 {
                    switch cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt) {
                    case .clean:
                        throw ContainerizationError(
                            .internalError,
                            message: "refusing to replace \(path): the destination changed before the export could be installed; the raced destination was restored")
                    case .retained(let cleanupErrno):
                        throw ContainerizationError(
                            .internalError,
                            message:
                                "refusing to replace \(path): the destination changed before the export could be installed; the raced destination was restored, but the staged export could not be cleaned up (\(String(cString: strerror(cleanupErrno)))) and remains at \(stagedPath)"
                        )
                    }
                }
                let rollbackErrno = errno
                throw ContainerizationError(
                    .internalError,
                    message:
                        "the replacement is installed at \(path), but the raced destination could not be restored (\(String(cString: strerror(rollbackErrno)))); the displaced entry remains at \(stagedPath)"
                )
            }

            let cleanupResult = cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt)
            guard case .retained(let cleanupErrno) = cleanupResult else { return }

            let rollbackFlags = UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_SWAP)
            if operations.rollback(parent, name, parent, stagedName, rollbackFlags) == 0 {
                switch cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt) {
                case .clean:
                    throw ContainerizationError(
                        .internalError,
                        message: "could not clean up the displaced archive at \(path): \(String(cString: strerror(cleanupErrno))); the previous destination was restored")
                case .retained(let stagedCleanupErrno):
                    throw ContainerizationError(
                        .internalError,
                        message:
                            "could not clean up the displaced archive at \(path): \(String(cString: strerror(cleanupErrno))); the previous destination was restored, but the staged export could not be cleaned up (\(String(cString: strerror(stagedCleanupErrno)))) and remains at \(stagedPath)"
                    )
                }
            }

            let rollbackErrno = errno
            throw ContainerizationError(
                .internalError,
                message:
                    "the replacement is installed at \(path), but the previous archive could not be cleaned up (\(String(cString: strerror(cleanupErrno)))) or restored (\(String(cString: strerror(rollbackErrno)))); it remains at \(stagedPath)"
            )
        }

        // With no observed destination, an entry appearing after validation wins untouched.
        let flags = UInt32(RENAME_NOFOLLOW_ANY) | UInt32(RENAME_EXCL)
        guard operations.rename(parent, stagedName, parent, name, flags) == 0 else {
            let renameErrno = errno
            let cleanupResult = cleanupStage(in: parent, named: stagedName, using: operations.unlinkAt)
            if renameErrno == EEXIST {
                switch cleanupResult {
                case .clean:
                    throw ContainerizationError(.exists, message: "\(path) appeared before the export could be installed; pass --force to replace it")
                case .retained(let cleanupErrno):
                    throw ContainerizationError(
                        .exists,
                        message:
                            "\(path) appeared before the export could be installed; the staged export could not be cleaned up (\(String(cString: strerror(cleanupErrno)))) and remains at \(stagedPath); pass --force to replace the destination"
                    )
                }
            }
            switch cleanupResult {
            case .clean:
                throw ContainerizationError(
                    .internalError,
                    message: "could not put the export at \(path): \(String(cString: strerror(renameErrno)))")
            case .retained(let cleanupErrno):
                throw ContainerizationError(
                    .internalError,
                    message:
                        "could not put the export at \(path): \(String(cString: strerror(renameErrno))); the staged export could not be cleaned up (\(String(cString: strerror(cleanupErrno)))) and remains at \(stagedPath)"
                )
            }
        }
    }

    private enum StageCleanupResult {
        case clean
        case retained(errno: Int32)
    }

    private static func cleanupStage(in directory: Int32, named name: String, using unlinkAt: UnlinkAt) -> StageCleanupResult {
        guard unlinkAt(directory, name, 0) != 0 else { return .clean }
        let cleanupErrno = errno
        return cleanupErrno == ENOENT ? .clean : .retained(errno: cleanupErrno)
    }

    private struct FilesystemFailure: Error {
        let errno: Int32
    }

    private static func openDirectoryWithoutFollowingSymlinks(_ path: String, output: String) throws -> Int32 {
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "export failed: could not open the parent of \(output): \(String(cString: strerror(errno)))")
        }

        var isRootComponent = true
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let componentName = String(component)
            var next = openat(directory, componentName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)

            // macOS exposes stable root-owned aliases such as /var -> /private/var. Accept
            // only those root-level system aliases; user-controlled symlink components remain
            // refused and are never used for staging.
            if next < 0, isRootComponent {
                var info = stat()
                if fstatat(directory, componentName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                    info.st_mode & S_IFMT == S_IFLNK,
                    info.st_uid == 0
                {
                    next = openat(directory, componentName, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                }
            }

            if next < 0 {
                let openErrno = errno
                _ = close(directory)
                throw ContainerizationError(
                    .invalidArgument,
                    message: "refusing to export to \(output): its parent contains a symbolic link or is not a directory (\(String(cString: strerror(openErrno))))")
            }
            _ = close(directory)
            directory = next
            isRootComponent = false
        }
        return directory
    }

    private static func stageArchive(_ archive: URL, in directory: Int32, named name: String) throws {
        let archivePath = archive.path(percentEncoded: false)
        if Darwin.renameatx_np(AT_FDCWD, archivePath, directory, name, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        let renameErrno = errno
        guard renameErrno == EXDEV else { throw FilesystemFailure(errno: renameErrno) }

        let source = Darwin.open(archivePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw FilesystemFailure(errno: errno) }
        defer { _ = close(source) }

        let destination = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw FilesystemFailure(errno: errno) }
        defer { _ = close(destination) }

        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }

        while true {
            let count = Darwin.read(source, buffer, capacity)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FilesystemFailure(errno: errno)
            }

            var offset = 0
            while offset < count {
                let written = Darwin.write(destination, buffer.advanced(by: offset), count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw FilesystemFailure(errno: written == 0 ? EIO : errno)
                }
            }
        }
        guard fsync(destination) == 0 else { throw FilesystemFailure(errno: errno) }
    }
}
