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

private enum InjectedExportError: Error {
    case staging
}

private final class ConcurrentExportOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = (successes: 0, existsFailures: 0, otherFailures: 0)

    var value: (successes: Int, existsFailures: Int, otherFailures: Int) {
        lock.withLock { storage }
    }

    func recordSuccess() {
        lock.withLock { storage.successes += 1 }
    }

    func recordFailure(_ error: Error) {
        lock.withLock {
            if let error = error as? ContainerizationError, error.code == .exists {
                storage.existsFailures += 1
            } else {
                storage.otherFailures += 1
            }
        }
    }
}

private func systemRename(
    fromDirectory: Int32,
    from: String,
    toDirectory: Int32,
    to: String,
    flags: UInt32
) -> Int32 {
    Darwin.renameatx_np(fromDirectory, from, toDirectory, to, flags)
}

@discardableResult
private func createFile(in directory: Int32, named name: String, contents: Data) -> Bool {
    let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    return contents.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count
    }
}

/// `container export -o` must never take an existing path with it.
struct ExportDestinationTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func archive(in dir: URL, _ content: String = "archive bytes", named name: String = "archive.tar") throws -> URL {
        let file = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: file)
        return file
    }

    private func leftovers(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
    }

    @Test("a new output path is written")
    func newOutput() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try ExportDestination.commit(archive: try archive(in: dir), to: out, force: false)
        #expect(try Data(contentsOf: out) == Data("archive bytes".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("an existing regular file is refused without --force and left untouched")
    func existingFileRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(archive: try archive(in: dir), to: out, force: false)
        }
        #expect(error?.code == .exists)
        #expect(error?.message.contains("--force") == true)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
    }

    @Test("directories are refused, forced or not, without touching their contents")
    func directoryRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for populated in [false, true] {
            let out = dir.appendingPathComponent(populated ? "populated" : "empty")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if populated {
                try Data("keep me".utf8).write(to: out.appendingPathComponent("important.txt"))
            }
            for force in [false, true] {
                let error = #expect(throws: ContainerizationError.self) {
                    try ExportDestination.commit(
                        archive: try archive(in: dir, named: "archive-\(populated)-\(force).tar"),
                        to: out,
                        force: force)
                }
                #expect(error?.message.contains("directory") == true)
            }
            if populated {
                #expect(try Data(contentsOf: out.appendingPathComponent("important.txt")) == Data("keep me".utf8))
            }
        }
    }

    @Test("a symlink is refused, and its target is not replaced")
    func symlinkRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
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

    @Test("a symlinked output parent is refused before staging")
    func symlinkedParentIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target-directory")
        let link = dir.appendingPathComponent("linked-directory")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let archive = try archive(in: dir)

        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: archive,
                to: link.appendingPathComponent("rootfs.tar"),
                force: false)
        }
        #expect(error?.code == .invalidArgument)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("rootfs.tar").path))
        #expect(try leftovers(in: target).isEmpty)
    }

    @Test("--force replaces an observed regular file in one atomic step")
    func forcedReplacement() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        let oldDescriptor = Darwin.open(out.path, O_RDONLY)
        #expect(oldDescriptor >= 0)
        defer { if oldDescriptor >= 0 { _ = close(oldDescriptor) } }

        try ExportDestination.commit(archive: try archive(in: dir, "replacement"), to: out, force: true)

        #expect(try Data(contentsOf: out) == Data("replacement".utf8))
        if oldDescriptor >= 0 {
            let oldHandle = FileHandle(fileDescriptor: oldDescriptor, closeOnDealloc: false)
            #expect(try oldHandle.readToEnd() == Data("previous".utf8))
        }
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a destination appearing after validation is never clobbered")
    func destinationAppearsBeforeCommit() throws {
        for force in [false, true] {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let out = dir.appendingPathComponent("rootfs.tar")
            let contender = Data("racing destination".utf8)
            var operations = ExportDestination.Operations()
            operations.rename = { fromDirectory, from, toDirectory, to, flags in
                #expect(flags & UInt32(RENAME_EXCL) != 0)
                #expect(createFile(in: toDirectory, named: to, contents: contender))
                return systemRename(
                    fromDirectory: fromDirectory,
                    from: from,
                    toDirectory: toDirectory,
                    to: to,
                    flags: flags)
            }
            let error = #expect(throws: ContainerizationError.self) {
                try ExportDestination.commit(
                    archive: try archive(in: dir),
                    to: out,
                    force: force,
                    operations: operations)
            }
            #expect(error?.code == .exists)
            #expect(try Data(contentsOf: out) == contender)
            #expect(try leftovers(in: dir).isEmpty)
        }
    }

    @Test("concurrent no-force exporters have exactly one winner")
    func concurrentNoForceExporters() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        let first = try archive(in: dir, "first", named: "first.tar")
        let second = try archive(in: dir, "second", named: "second.tar")
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = ConcurrentExportOutcomes()

        for input in [first, second] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    var operations = ExportDestination.Operations()
                    operations.rename = { fromDirectory, from, toDirectory, to, flags in
                        ready.signal()
                        release.wait()
                        return systemRename(
                            fromDirectory: fromDirectory,
                            from: from,
                            toDirectory: toDirectory,
                            to: to,
                            flags: flags)
                    }
                    try ExportDestination.commit(
                        archive: input,
                        to: out,
                        force: false,
                        operations: operations)
                    outcomes.recordSuccess()
                } catch {
                    outcomes.recordFailure(error)
                }
            }
        }

        #expect(ready.wait(timeout: .now() + 5) == .success)
        #expect(ready.wait(timeout: .now() + 5) == .success)
        release.signal()
        release.signal()
        #expect(group.wait(timeout: .now() + 5) == .success)

        let result = outcomes.value
        #expect(result.successes == 1)
        #expect(result.existsFailures == 1)
        #expect(result.otherFailures == 0)
        let bytes = try Data(contentsOf: out)
        #expect(bytes == Data("first".utf8) || bytes == Data("second".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a symlink raced into a forced destination is not replaced or followed")
    func racedSymlinkIsNotReplaced() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        let target = dir.appendingPathComponent("target.tar")
        try Data("previous".utf8).write(to: out)
        try Data("target".utf8).write(to: target)

        var operations = ExportDestination.Operations()
        operations.rename = { fromDirectory, from, toDirectory, to, flags in
            #expect(flags & UInt32(RENAME_NOFOLLOW_ANY) != 0)
            #expect(unlinkat(toDirectory, to, 0) == 0)
            #expect(symlinkat(target.path, toDirectory, to) == 0)
            return systemRename(
                fromDirectory: fromDirectory,
                from: from,
                toDirectory: toDirectory,
                to: to,
                flags: flags)
        }
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        #expect(error?.code == .internalError)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.path) == target.path)
        #expect(try Data(contentsOf: target) == Data("target".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a rollback failure after a raced entry reports both committed paths without unlinking the contender")
    func racedEntryRollbackFailureIsHonest() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        let target = dir.appendingPathComponent("target.tar")
        try Data("previous".utf8).write(to: out)
        try Data("target".utf8).write(to: target)
        var stagedName: String?
        var cleanupCalls = 0

        var operations = ExportDestination.Operations()
        operations.rename = { fromDirectory, from, toDirectory, to, flags in
            stagedName = from
            #expect(flags & UInt32(RENAME_NOFOLLOW_ANY) != 0)
            #expect(unlinkat(toDirectory, to, 0) == 0)
            #expect(symlinkat(target.path, toDirectory, to) == 0)
            return systemRename(
                fromDirectory: fromDirectory,
                from: from,
                toDirectory: toDirectory,
                to: to,
                flags: flags)
        }
        operations.rollback = { _, _, _, _, flags in
            #expect(flags & UInt32(RENAME_NOFOLLOW_ANY) != 0)
            #expect(flags & UInt32(RENAME_SWAP) != 0)
            errno = EBUSY
            return -1
        }
        operations.unlinkAt = { _, _, _ in
            cleanupCalls += 1
            errno = EIO
            return -1
        }

        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        let retained = dir.appendingPathComponent(try #require(stagedName))
        #expect(error?.code == .internalError)
        #expect(error?.message.contains("replacement is installed at \(out.path)") == true)
        #expect(error?.message.contains(String(cString: strerror(EBUSY))) == true)
        #expect(error?.message.contains(retained.path) == true)
        #expect(cleanupCalls == 0)
        #expect(try Data(contentsOf: out) == Data("replacement".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: retained.path) == target.path)
        #expect(try Data(contentsOf: target) == Data("target".utf8))
    }

    @Test("a staging failure preserves the old destination and removes a partial stage")
    func stagingFailureKeepsPrevious() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var operations = ExportDestination.Operations()
        operations.stage = { _, directory, name in
            #expect(createFile(in: directory, named: name, contents: Data("partial".utf8)))
            throw InjectedExportError.staging
        }
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        #expect(error?.code == .internalError)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a persistent partial-stage cleanup failure names the retained export")
    func stagingCleanupFailureReportsResidue() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var stagedName: String?
        var operations = ExportDestination.Operations()
        operations.stage = { _, directory, name in
            stagedName = name
            #expect(createFile(in: directory, named: name, contents: Data("partial".utf8)))
            throw InjectedExportError.staging
        }
        operations.unlinkAt = { _, name, flags in
            #expect(name == stagedName)
            #expect(flags == 0)
            errno = EIO
            return -1
        }

        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        let retained = dir.appendingPathComponent(try #require(stagedName))
        #expect(error?.code == .internalError)
        #expect(error?.message.contains(String(cString: strerror(EIO))) == true)
        #expect(error?.message.contains(retained.path) == true)
        #expect(try Data(contentsOf: retained) == Data("partial".utf8))
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
    }

    @Test("a displaced archive cleanup failure restores the previous destination")
    func displacedCleanupFailureRollsBack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var unlinkCalls = 0
        var operations = ExportDestination.Operations()
        operations.unlinkAt = { directory, name, flags in
            unlinkCalls += 1
            if unlinkCalls == 1 {
                errno = EIO
                return -1
            }
            return Darwin.unlinkat(directory, name, flags)
        }

        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        #expect(error?.message.contains("previous destination was restored") == true)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a missing staged entry is treated as clean")
    func missingStageIsClean() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var rollbackCalls = 0
        var operations = ExportDestination.Operations()
        operations.unlinkAt = { directory, name, flags in
            #expect(Darwin.unlinkat(directory, name, flags) == 0)
            errno = ENOENT
            return -1
        }
        operations.rollback = { _, _, _, _, _ in
            rollbackCalls += 1
            errno = EIO
            return -1
        }

        try ExportDestination.commit(
            archive: try archive(in: dir, "replacement"),
            to: out,
            force: true,
            operations: operations)

        #expect(rollbackCalls == 0)
        #expect(try Data(contentsOf: out) == Data("replacement".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("a failed displaced cleanup and rollback reports the committed replacement")
    func displacedCleanupAndRollbackFailureIsHonest() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var operations = ExportDestination.Operations()
        operations.unlinkAt = { _, _, _ in
            errno = EIO
            return -1
        }
        operations.rollback = { _, _, _, _, _ in
            errno = EBUSY
            return -1
        }

        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        #expect(error?.message.contains("replacement is installed") == true)
        #expect(error?.message.contains(String(cString: strerror(EIO))) == true)
        #expect(error?.message.contains(String(cString: strerror(EBUSY))) == true)
        #expect(error?.message.contains("remains at") == true)
        #expect(try Data(contentsOf: out) == Data("replacement".utf8))
        #expect(try leftovers(in: dir).count == 1)
    }

    @Test("a final commit failure keeps the previous file and names the path")
    func finalMoveFailureKeepsPrevious() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var operations = ExportDestination.Operations()
        operations.rename = { _, _, _, _, _ in
            errno = EIO
            return -1
        }
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains("destination was not changed") == true)
        #expect(error?.message.contains(out.path) == true)
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
        #expect(try leftovers(in: dir).isEmpty)
    }

    @Test("directory-substitution cleanup reports the retained path without recursive removal")
    func cleanupDoesNotRemoveDirectories() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("rootfs.tar")
        try Data("previous".utf8).write(to: out)
        var replacedStage: String?
        var cleanupErrno: Int32?
        var operations = ExportDestination.Operations()
        operations.rename = { fromDirectory, from, _, _, _ in
            #expect(unlinkat(fromDirectory, from, 0) == 0)
            #expect(mkdirat(fromDirectory, from, 0o700) == 0)
            let stagedDirectory = openat(fromDirectory, from, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            #expect(stagedDirectory >= 0)
            if stagedDirectory >= 0 {
                #expect(createFile(in: stagedDirectory, named: "sentinel", contents: Data("keep".utf8)))
                _ = close(stagedDirectory)
            }
            replacedStage = from
            errno = EIO
            return -1
        }
        operations.unlinkAt = { directory, name, flags in
            #expect(flags == 0)
            let result = Darwin.unlinkat(directory, name, flags)
            let unlinkErrno = errno
            #expect(result != 0)
            cleanupErrno = unlinkErrno
            errno = unlinkErrno
            return result
        }
        let error = #expect(throws: ContainerizationError.self) {
            try ExportDestination.commit(
                archive: try archive(in: dir, "replacement"),
                to: out,
                force: true,
                operations: operations)
        }
        let stagedName = try #require(replacedStage)
        let staged = dir.appendingPathComponent(stagedName).path
        let retainedErrno = try #require(cleanupErrno)
        #expect(error?.message.contains(staged) == true)
        #expect(error?.message.contains(String(cString: strerror(retainedErrno))) == true)
        var info = stat()
        #expect(lstat(staged, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged + "/sentinel")) == Data("keep".utf8))
        #expect(try Data(contentsOf: out) == Data("previous".utf8))
    }
}
