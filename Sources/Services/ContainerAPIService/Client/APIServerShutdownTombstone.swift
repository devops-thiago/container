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

import ContainerPlugin
import ContainerizationError
import Darwin
import Foundation

public struct APIServerShutdownTombstone: Codable, Equatable, Sendable {
    public let lifecycleGeneration: String
    public let processNonce: String
    public let pid: Int32
    public let processStartSeconds: UInt64
    public let processStartMicroseconds: UInt64

    public init(
        lifecycleGeneration: String,
        processNonce: String,
        pid: Int32,
        processStartSeconds: UInt64,
        processStartMicroseconds: UInt64
    ) {
        self.lifecycleGeneration = lifecycleGeneration
        self.processNonce = processNonce
        self.pid = pid
        self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds
    }

    public static func currentProcess(
        lifecycleGeneration: String,
        processNonce: String
    ) throws -> Self {
        let pid = getpid()
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard actualSize == expectedSize else {
            throw ContainerizationError(
                .internalError,
                message: "failed to read API-server process birth time for PID \(pid)"
            )
        }
        return Self(
            lifecycleGeneration: lifecycleGeneration,
            processNonce: processNonce,
            pid: pid,
            processStartSeconds: info.pbi_start_tvsec,
            processStartMicroseconds: info.pbi_start_tvusec
        )
    }
}

public enum APIServerShutdownTombstoneStore {
    public enum CommitError: Error, LocalizedError, Sendable {
        case outcomeIndeterminate(String)

        public var errorDescription: String? {
            switch self {
            case .outcomeIndeterminate(let message):
                return message
            }
        }
    }

    private static let directoryName = "apiserver"
    private static let filenamePrefix = "shutdown-tombstone."
    private static let filenameSuffix = ".json"
    private static let maximumRecordSize: off_t = 64 * 1024

    public static func tombstoneURL(
        appRoot: URL,
        lifecycleGeneration: String
    ) throws -> URL {
        try validateGeneration(lifecycleGeneration)
        guard appRoot.isFileURL else {
            throw ContainerizationError(.invalidArgument, message: "application root must be a file URL")
        }
        return appRoot.standardizedFileURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(
                "\(filenamePrefix)\(lifecycleGeneration)\(filenameSuffix)",
                isDirectory: false
            )
    }

    public static func load(
        appRoot: URL,
        lifecycleGeneration: String
    ) throws -> APIServerShutdownTombstone? {
        let recordURL = try tombstoneURL(
            appRoot: appRoot,
            lifecycleGeneration: lifecycleGeneration
        )
        let fd = open(recordURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ioError("open shutdown tombstone \(recordURL.path)")
        }
        defer { close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw ioError("inspect shutdown tombstone \(recordURL.path)")
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_size > 0,
            status.st_size <= maximumRecordSize
        else {
            throw ContainerizationError(
                .invalidState,
                message: "shutdown tombstone \(recordURL.path) is not a valid record file"
            )
        }

        var data = Data(count: Int(status.st_size))
        let count = try data.withUnsafeMutableBytes {
            (buffer: UnsafeMutableRawBufferPointer) throws -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.read(
                    fd,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    throw ioError("read shutdown tombstone \(recordURL.path)")
                }
            }
            return offset
        }
        guard count == data.count else {
            throw ContainerizationError(
                .invalidState,
                message: "shutdown tombstone \(recordURL.path) was truncated"
            )
        }

        let tombstone: APIServerShutdownTombstone
        do {
            tombstone = try JSONDecoder().decode(APIServerShutdownTombstone.self, from: data)
        } catch {
            throw ContainerizationError(
                .invalidState,
                message: "shutdown tombstone \(recordURL.path) is malformed: \(error)"
            )
        }
        try validate(tombstone)
        guard tombstone.lifecycleGeneration == lifecycleGeneration else {
            throw ContainerizationError(
                .invalidState,
                message: "shutdown tombstone generation does not match its storage key"
            )
        }
        return tombstone
    }

    public static func commit(
        _ tombstone: APIServerShutdownTombstone,
        appRoot: URL
    ) throws {
        try validate(tombstone)
        let recordURL = try tombstoneURL(
            appRoot: appRoot,
            lifecycleGeneration: tombstone.lifecycleGeneration
        )
        let directory = recordURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let directoryExisted = fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        )
        if directoryExisted {
            guard isDirectory.boolValue else {
                throw ContainerizationError(
                    .invalidState,
                    message: "shutdown tombstone directory is not a directory"
                )
            }
        } else {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "could not create shutdown tombstone directory: \(error)"
                )
            }
        }
        do {
            try syncDirectory(directory.deletingLastPathComponent())
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "could not make shutdown tombstone directory durable: \(error)"
            )
        }

        if let existing = try load(
            appRoot: appRoot,
            lifecycleGeneration: tombstone.lifecycleGeneration
        ) {
            guard existing == tombstone else {
                throw ContainerizationError(
                    .invalidState,
                    message: "a different shutdown tombstone already exists for lifecycle generation \(tombstone.lifecycleGeneration)"
                )
            }
            try syncFile(recordURL)
            try syncDirectory(directory)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tombstone)
        let temporaryURL = directory.appendingPathComponent(
            ".\(recordURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let fd = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw ioError("create temporary shutdown tombstone \(temporaryURL.path)")
        }

        var temporaryExists = true
        defer {
            close(fd)
            if temporaryExists {
                unlink(temporaryURL.path)
            }
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws -> Void in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw ioError("write temporary shutdown tombstone \(temporaryURL.path)")
                }
            }
        }
        guard fsync(fd) == 0 else {
            throw ioError("sync temporary shutdown tombstone \(temporaryURL.path)")
        }

        guard renamex_np(temporaryURL.path, recordURL.path, UInt32(RENAME_EXCL)) == 0 else {
            let renameError = errno
            if renameError == EEXIST,
                let existing = try load(
                    appRoot: appRoot,
                    lifecycleGeneration: tombstone.lifecycleGeneration
                ),
                existing == tombstone
            {
                try syncFile(recordURL)
                try syncDirectory(directory)
                return
            }
            throw ioError(
                "publish shutdown tombstone \(recordURL.path)",
                code: renameError
            )
        }
        temporaryExists = false

        do {
            try syncDirectory(directory)
        } catch {
            let commitError = error
            do {
                try rollbackPublishedRecord(recordURL, in: directory)
            } catch {
                throw CommitError.outcomeIndeterminate(
                    "shutdown tombstone publication may be durable after commit error \(commitError) "
                        + "and rollback error \(error)"
                )
            }
            throw commitError
        }
    }

    private static func rollbackPublishedRecord(
        _ record: URL,
        in directory: URL
    ) throws {
        if unlink(record.path) != 0, errno != ENOENT {
            throw ioError("roll back shutdown tombstone \(record.path)")
        }
        try syncDirectory(directory)
    }

    private static func validate(_ tombstone: APIServerShutdownTombstone) throws {
        try validateGeneration(tombstone.lifecycleGeneration)
        guard !tombstone.processNonce.isEmpty,
            tombstone.pid > 0,
            tombstone.processStartSeconds > 0,
            tombstone.processStartMicroseconds < 1_000_000
        else {
            throw ContainerizationError(.invalidArgument, message: "shutdown tombstone identity is invalid")
        }
    }

    private static func validateGeneration(_ lifecycleGeneration: String) throws {
        guard PluginLoader.isValidLifecycleGeneration(lifecycleGeneration) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "lifecycle generation must contain only ASCII letters, digits, and hyphens"
            )
        }
    }

    private static func syncFile(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ioError("open shutdown tombstone \(file.path) for sync")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ioError("sync shutdown tombstone \(file.path)")
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ioError("open shutdown tombstone directory \(directory.path) for sync")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ioError("sync shutdown tombstone directory \(directory.path)")
        }
    }

    private static func ioError(
        _ operation: String,
        code: Int32 = errno
    ) -> ContainerizationError {
        ContainerizationError(
            .internalError,
            message: "could not \(operation): \(String(cString: strerror(code)))"
        )
    }
}
