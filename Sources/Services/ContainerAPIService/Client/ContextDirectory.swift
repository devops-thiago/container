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

import Darwin
import Foundation

/// A selected build directory pinned for the lifetime of a transfer. All lookup steps
/// are relative to owned directory descriptors. Symlinks are interpreted explicitly;
/// the kernel never follows a replaceable path component on our behalf.
public final class ContextDirectory: @unchecked Sendable {
    public let root: URL
    private let canonicalPath: String
    private let descriptor: Int32

    public init(_ root: URL) throws {
        guard !root.path.utf8.contains(0) else { throw Error.invalidPath }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        // Opening the selected root establishes the capability for this transfer. A
        // sandbox folder grant covers this directory, not read access to its ancestors.
        // Every later lookup stays relative to this descriptor, even if its name moves.
        let directory = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posixError() }
        // Derive the physical spelling from the opened directory, rather than resolving
        // its replaceable pathname again. Foundation retains aliases such as /var.
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = bytes.withUnsafeMutableBytes { fcntl(directory, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else {
            let error = Self.posixError()
            Darwin.close(directory)
            throw error
        }
        self.canonicalPath = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        self.descriptor = directory
    }

    deinit { Darwin.close(descriptor) }

    public func relativePath(_ path: URL) throws -> String {
        let path = path.path
        for root in [self.root.path, canonicalPath] {
            if path == root { return "" }
            let prefix = root == "/" ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        throw Error.outsideRoot
    }

    /// The returned file owns the descriptor used for both metadata and reads. A path
    /// rename after this call cannot retarget either operation. Only literal symlink
    /// entries (tar/JSON metadata) pass `followFinalSymlink: false`.
    public func open(_ path: String, followFinalSymlink: Bool = true) throws -> File {
        guard !path.utf8.contains(0), path.utf8.count <= Int(PATH_MAX) else { throw Error.invalidPath }
        let relative = path.hasPrefix("/") ? try relativePath(URL(fileURLWithPath: path)) : path
        var components = relative.split(separator: "/").map(String.init)
        var position = 0
        var links = 0
        let first = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard first >= 0 else { throw Self.posixError() }
        var directories = [first]
        defer { directories.forEach { Darwin.close($0) } }

        while position < components.count {
            let component = components[position]
            position += 1
            if component == "." { continue }
            if component == ".." {
                guard directories.count > 1 else { throw Error.outsideRoot }
                Darwin.close(directories.removeLast())
                continue
            }
            let directory = directories[directories.count - 1]
            var metadata = stat()
            guard fstatat(directory, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
            let isLast = position == components.count
            if metadata.st_mode & S_IFMT == S_IFLNK {
                let target = try Self.linkTarget(directory: directory, name: component)
                if isLast && !followFinalSymlink {
                    // No target is opened: tar carries the literal link, even if dangling
                    // or outside the context. Detect replacement while reading its header.
                    var current = stat()
                    guard fstatat(directory, component, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
                    guard current.st_ino == metadata.st_ino, current.st_dev == metadata.st_dev,
                        current.st_mode & S_IFMT == S_IFLNK
                    else { throw Error.changed }
                    return File(metadata: metadata, linkTarget: target)
                }
                links += 1
                guard links <= 40 else { throw Error.symlinkLoop }
                let targetPath: String
                if target.hasPrefix("/") {
                    targetPath = try relativePath(URL(fileURLWithPath: target))
                    while directories.count > 1 { Darwin.close(directories.removeLast()) }
                } else {
                    targetPath = target
                }
                // Leave dot-dot components for the descriptor stack to interpret. Lexical
                // standardization before following a preceding link changes its meaning.
                components = targetPath.split(separator: "/").map(String.init) + components.dropFirst(position)
                position = 0
                continue
            }

            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY | (isLast ? 0 : O_DIRECTORY)
            let file = openat(directory, component, flags)
            guard file >= 0 else { throw Self.posixError() }
            let opened: File
            do { opened = try File(descriptor: file) } catch {
                Darwin.close(file)
                throw error
            }
            if isLast { return opened }
            guard opened.isDirectory else { throw Error.unsupportedType }
            let next = withExtendedLifetime(opened) { fcntl(file, F_DUPFD_CLOEXEC, 0) }
            guard next >= 0 else { throw Self.posixError() }
            directories.append(next)
        }
        let file = fcntl(directories[directories.count - 1], F_DUPFD_CLOEXEC, 0)
        guard file >= 0 else { throw Self.posixError() }
        do { return try File(descriptor: file) } catch {
            Darwin.close(file)
            throw error
        }
    }

    public final class File: @unchecked Sendable {
        public let metadata: stat
        public let linkTarget: String?
        private let descriptor: Int32?

        fileprivate init(descriptor: Int32) throws {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw ContextDirectory.posixError() }
            guard metadata.st_mode & S_IFMT == S_IFREG || metadata.st_mode & S_IFMT == S_IFDIR else {
                throw Error.unsupportedType
            }
            self.metadata = metadata
            self.descriptor = descriptor
            self.linkTarget = nil
        }

        fileprivate init(metadata: stat, linkTarget: String) {
            self.metadata = metadata
            self.linkTarget = linkTarget
            self.descriptor = nil
        }

        deinit { if let descriptor { Darwin.close(descriptor) } }

        public var isDirectory: Bool { metadata.st_mode & S_IFMT == S_IFDIR }
        public var isRegular: Bool { metadata.st_mode & S_IFMT == S_IFREG }
        public var modificationDate: Date {
            Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        }

        public func read(offset: UInt64, length: Int) throws -> Data {
            guard length >= 0, offset <= UInt64(Int64.max) else { throw Error.invalidRange }
            if isDirectory { return Data() }
            guard isRegular, let descriptor, metadata.st_size >= 0 else { throw Error.unsupportedType }
            let available = UInt64(metadata.st_size) > offset ? UInt64(metadata.st_size) - offset : 0
            // The fallback protocol historically treats zero/omitted length as "to EOF".
            let count = Int(length == 0 ? available : min(UInt64(length), available))
            var data = Data(count: count)
            var consumed = 0
            while consumed < count {
                let read = data.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress!.advanced(by: consumed), count - consumed, off_t(offset) + off_t(consumed))
                }
                if read < 0 && errno == EINTR { continue }
                guard read >= 0 else { throw ContextDirectory.posixError() }
                guard read > 0 else { throw Error.changed }
                consumed += read
            }
            return data
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case outsideRoot
        case invalidPath
        case invalidRange
        case symlinkLoop
        case changed
        case unsupportedType

        public var description: String {
            switch self {
            case .outsideRoot: "build-context path resolves outside the selected directory"
            case .invalidPath: "invalid build-context path"
            case .invalidRange: "invalid build-context byte range"
            case .symlinkLoop: "too many symbolic links in build-context path"
            case .changed: "build-context entry changed during transfer; retry the build"
            case .unsupportedType: "unsupported build-context file type"
            }
        }
    }

    private static func linkTarget(directory: Int32, name: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let count = bytes.withUnsafeMutableBytes { readlinkat(directory, name, $0.baseAddress!, $0.count) }
        guard count >= 0 else { throw posixError() }
        guard count < bytes.count, let result = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw Error.invalidPath }
        return result
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
