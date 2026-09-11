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

import ContainerizationArchive
import ContainerizationOS
import CryptoKit
import Foundation

public final class Archiver: Sendable {
    public struct ArchiveEntryInfo: Sendable, Codable {
        public let pathOnHost: URL
        public let pathInArchive: URL

        public let owner: UInt32?
        public let group: UInt32?
        public let permissions: UInt16?

        public init(
            pathOnHost: URL,
            pathInArchive: URL,
            owner: UInt32? = nil,
            group: UInt32? = nil,
            permissions: UInt16? = nil
        ) {
            self.pathOnHost = pathOnHost
            self.pathInArchive = pathInArchive
            self.owner = owner
            self.group = group
            self.permissions = permissions
        }
    }

    public static func compress(
        source: URL,
        destination: URL,
        followSymlinks: Bool = false,
        writerConfiguration: ArchiveWriterConfiguration = ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip),
        contextDirectory: ContextDirectory? = nil,
        beforeReading: () throws -> Void = {},
        closure: (URL) -> ArchiveEntryInfo?
    ) throws -> SHA256.Digest {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let context = try contextDirectory ?? ContextDirectory(source.isDirectory ? source : source.deletingLastPathComponent())

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)

        var hasher = SHA256()

        do {
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            guard
                let enumerator = FileManager.default.enumerator(atPath: source.path)
            else {
                throw Error.fileDoesNotExist(source)
            }

            var entryInfo = [ArchiveEntryInfo]()
            if !source.isDirectory {
                if let info = closure(source) {
                    entryInfo.append(info)
                }
            } else {
                let relPaths = enumerator.compactMap { $0 as? String }
                for relPath in relPaths.sorted(by: { $0 < $1 }) {
                    let url = source.appending(path: relPath).standardizedFileURL
                    guard let info = closure(url) else {
                        continue
                    }
                    entryInfo.append(info)
                }
            }

            let archiver = try ArchiveWriter(
                configuration: writerConfiguration
            )
            try archiver.open(file: destination)

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys

            for info in entryInfo {
                let file = try context.open(context.relativePath(info.pathOnHost), followFinalSymlink: followSymlinks)
                guard let entry = try Self._createEntry(entryInfo: info, file: file) else {
                    throw Error.failedToCreateEntry
                }
                hasher.update(data: try encoder.encode(entry))
                try Self._compressFile(file: file, entry: entry, archiver: archiver, hasher: &hasher, beforeReading: beforeReading)
            }
            try archiver.finishEncoding()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return hasher.finalize()
    }

    // MARK: private functions
    private static func _compressFile(file: ContextDirectory.File, entry: WriteEntry, archiver: ArchiveWriter, hasher: inout SHA256, beforeReading: () throws -> Void) throws {
        let writer = archiver.makeTransactionWriter()
        let bufferSize = Int(1.mib())
        try writer.writeHeader(entry: entry)
        if entry.fileType == .regular {
            try beforeReading()
            // We need to write the data into the archive only if its a regular file
            // Symlinks and directories require us to only write the archive header
            var offset: UInt64 = 0
            while offset < UInt64(file.metadata.st_size) {
                let data = try file.read(offset: offset, length: bufferSize)
                hasher.update(data: data)
                try data.withUnsafeBytes { pointer in
                    try writer.writeChunk(data: pointer)
                }
                offset += UInt64(data.count)
            }
        }
        try writer.finish()
    }

    private static func _createEntry(entryInfo: ArchiveEntryInfo, file: ContextDirectory.File, pathPrefix: String = "") throws -> WriteEntry? {
        let entry = WriteEntry()
        if let target = file.linkTarget {
            entry.fileType = .symbolicLink
            entry.symlinkTarget = target
        } else if file.isDirectory {
            entry.fileType = .directory
        } else if file.isRegular {
            entry.fileType = .regular
        } else {
            return nil
        }
        entry.permissions = file.metadata.st_mode & 0o7777
        entry.size = file.metadata.st_size
        entry.owner = file.metadata.st_uid
        entry.group = file.metadata.st_gid
        entry.creationDate = Date(timeIntervalSince1970: Double(file.metadata.st_birthtimespec.tv_sec) + Double(file.metadata.st_birthtimespec.tv_nsec) / 1_000_000_000)
        entry.modificationDate = file.modificationDate

        // Apply explicit overrides from ArchiveEntryInfo when provided
        if let overrideOwner = entryInfo.owner {
            entry.owner = overrideOwner
        }
        if let overrideGroup = entryInfo.group {
            entry.group = overrideGroup
        }
        if let overridePerm = entryInfo.permissions {
            #if os(macOS)
            entry.permissions = overridePerm
            #else
            entry.permissions = UInt32(overridePerm)
            #endif
        }

        let pathTrimmed = Self._trimPathPrefix(entryInfo.pathInArchive.relativePath, pathPrefix: pathPrefix)
        entry.path = pathTrimmed
        return entry
    }

    private static func _trimPathPrefix(_ path: String, pathPrefix: String) -> String {
        guard !path.isEmpty && !pathPrefix.isEmpty else {
            return path
        }

        let decodedPath = path.removingPercentEncoding ?? path

        guard decodedPath.hasPrefix(pathPrefix) else {
            return decodedPath
        }
        let trimmedPath = String(decodedPath.suffix(from: pathPrefix.endIndex))
        return trimmedPath
    }
}

extension Archiver {
    public enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateEntry
        case fileDoesNotExist(_ url: URL)
        case failedToCreateInputStream(_ url: URL)
        case failedToReadFile(_ url: URL, _ underlying: Swift.Error?)

        public var description: String {
            switch self {
            case .failedToCreateEntry:
                return "failed to create entry"
            case .fileDoesNotExist(let url):
                return "file \(url.path) does not exist"
            case .failedToCreateInputStream(let url):
                return "failed to create input stream for \(url.path)"
            case .failedToReadFile(let url, let underlying):
                if let underlying {
                    return "failed to read file \(url.path): \(underlying)"
                }
                return "failed to read file \(url.path)"
            }
        }
    }
}

extension WriteEntry: @retroactive Encodable {
    enum CodingKeys: String, CodingKey {
        case path
        case fileType
        case size
        case permissions
        case owner
        case group
        case symlinkTarget
        case hardlink
        case creationDate
        case modificationDate
        case contentAccessDate
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileType.rawValue, forKey: .fileType)
        try container.encodeIfPresent(permissions, forKey: .permissions)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(symlinkTarget, forKey: .symlinkTarget)
        try container.encodeIfPresent(hardlink, forKey: .hardlink)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encodeIfPresent(contentAccessDate, forKey: .contentAccessDate)
    }
}
