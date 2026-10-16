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
import ContainerizationOCI
import Crypto
import Foundation

/// Opening a content blob: what `LocalContent` does, with an interrupted open restarted and
/// every other failure reported with its errno.
///
/// `LocalContent` throws `.notFound` for every failed open, whatever the system said, and
/// does not restart an open that returned EINTR. An open in an app group container, from a
/// process that is not the group's own (a test runner, a command line), goes through the
/// system's container protection and comes back EINTR now and then: about one open in a
/// thousand on a loaded Mac (devops-thiago/SiliconShip#435). Restarting an interrupted call
/// is the POSIX contract for EINTR, not a retry of a failure: the open did not happen. It is
/// bounded all the same, and what remains after the bound, like every other errno, is thrown
/// with the errno named.
public enum ContentBlobOpen {
    /// Opens a path; the descriptor, or -1 and the errno.
    public typealias Opener = @Sendable (String) -> (descriptor: Int32, errno: Int32)

    /// How many interrupted opens in a row are restarted before the last one is thrown.
    public static let attempts = 16

    /// `open(2)` read-only, not following a symlink at the blob's name, as `LocalContent` opens.
    public static let system: Opener = { path in
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    /// An open descriptor for the blob at `path`.
    ///
    /// - Throws: `.notFound` when nothing is there, or a symlink is, which the content store
    ///   never reads (ENOENT, ELOOP); `.internalError` for every other errno. Both carry the
    ///   errno.
    public static func descriptor(at path: URL, opener: Opener = system) throws -> Int32 {
        var interrupted = 0
        while true {
            let (descriptor, code) = opener(path.path(percentEncoded: false))
            if descriptor >= 0 {
                return descriptor
            }
            interrupted += 1
            guard code == EINTR, interrupted < attempts else {
                throw failure(errno: code, at: path, interrupted: interrupted)
            }
        }
    }

    /// Whether a blob is at `path`: false only when the open says nothing is (ENOENT, ELOOP),
    /// and any other failure thrown. An unreadable blob is not an absent one.
    public static func isPresent(at path: URL, opener: Opener = system) throws -> Bool {
        do {
            close(try descriptor(at: path, opener: opener))
            return true
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return false
        }
    }

    static func failure(errno code: Int32, at path: URL, interrupted: Int) -> ContainerizationError {
        let reason = "\(String(cString: strerror(code))) (errno \(code))"
        let location = path.path(percentEncoded: false)
        switch code {
        case ENOENT, ELOOP:
            return ContainerizationError(.notFound, message: "content at path \(location): \(reason)")
        case EINTR:
            return ContainerizationError(
                .internalError, message: "content at path \(location) could not be opened: \(reason), \(interrupted) times in a row")
        default:
            return ContainerizationError(.internalError, message: "content at path \(location) could not be opened: \(reason)")
        }
    }
}

/// A blob in the content store, read through one open descriptor: `LocalContent`, opened with
/// `ContentBlobOpen`.
public final class ContentBlob: Content {
    public let path: URL
    private let file: FileHandle

    public init(path: URL, opener: ContentBlobOpen.Opener = ContentBlobOpen.system) throws {
        let descriptor = try ContentBlobOpen.descriptor(at: path, opener: opener)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw ContainerizationError(.internalError, message: "failed to stat \(path.path(percentEncoded: false))")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw ContainerizationError(.internalError, message: "refusing to read non-regular file at \(path.path(percentEncoded: false))")
        }
        self.file = FileHandle(fileDescriptor: descriptor)
        self.path = path
    }

    public func digest() throws -> SHA256.Digest {
        var hasher = SHA256()
        try self.file.seek(toOffset: 0)
        while case let data = self.file.readData(ofLength: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        try self.file.seek(toOffset: 0)
        return hasher.finalize()
    }

    public func data(offset: UInt64 = 0, length size: Int = 0) throws -> Data? {
        try self.file.seek(toOffset: offset)
        if size == 0 {
            return try self.file.readToEnd()
        }
        return try self.file.read(upToCount: size)
    }

    public func data() throws -> Data {
        try self.boundedContents()
    }

    public func size() throws -> UInt64 {
        var status = stat()
        guard fstat(self.file.fileDescriptor, &status) == 0 else {
            throw ContainerizationError(.internalError, message: "could not determine file size for \(path.path(percentEncoded: false))")
        }
        return UInt64(status.st_size)
    }

    public func decode<T>() throws -> T where T: Decodable {
        try JSONDecoder().decode(T.self, from: self.boundedContents())
    }

    /// The whole blob, read through the open descriptor and refused past the limit
    /// `LocalContent` has for documents.
    private func boundedContents() throws -> Data {
        let limit = LocalContent.maxDecodedSize
        try self.file.seek(toOffset: 0)
        let data = try self.file.read(upToCount: limit + 1) ?? Data()
        try self.file.seek(toOffset: 0)
        guard data.count <= limit else {
            throw ContainerizationError(
                .invalidArgument,
                message:
                    "content at \(path.path(percentEncoded: false)) exceeds the \(limit) byte limit for documents read from the content store")
        }
        return data
    }

    deinit {
        try? self.file.close()
    }
}
