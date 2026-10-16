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
import NIOCore

/// The tar archives `archive` reads and writes: POSIX ustar, with pax extended headers for
/// what ustar cannot hold (long names, long link targets, sizes past 8 GiB). Uncompressed, as
/// the Docker CLI sends and expects them.
enum DockerTar {
    static let blockSize = 512

    enum EntryType: UInt8 {
        case file = 0x30  // "0"
        case hardLink = 0x31  // "1"
        case symlink = 0x32  // "2"
        case characterDevice = 0x33  // "3"
        case blockDevice = 0x34  // "4"
        case directory = 0x35  // "5"
        case fifo = 0x36  // "6"
        case contiguous = 0x37  // "7"
        case paxExtended = 0x78  // "x"
        case paxGlobal = 0x67  // "g"
        case gnuLongName = 0x4C  // "L"
        case gnuLongLink = 0x4B  // "K"
    }

    /// One entry to write.
    struct Entry {
        var name: String
        var type: EntryType
        var mode: UInt32
        var size: UInt64 = 0
        var mtime: Date
        var linkTarget: String = ""
    }

    /// The header blocks for `entry`: a pax header first when ustar's fields cannot hold it.
    static func header(_ entry: Entry) -> [UInt8] {
        var pax: [(String, String)] = []
        var name = entry.name
        var prefix = ""
        if name.utf8.count > 100 {
            if let split = splitForUstar(name) {
                (prefix, name) = split
            } else {
                pax.append(("path", entry.name))
                name = String(decoding: entry.name.utf8.prefix(100), as: UTF8.self)
            }
        }
        var link = entry.linkTarget
        if link.utf8.count > 100 {
            pax.append(("linkpath", link))
            link = String(decoding: link.utf8.prefix(100), as: UTF8.self)
        }
        let maxOctalSize: UInt64 = 0o77777777777
        if entry.size > maxOctalSize {
            pax.append(("size", String(entry.size)))
        }
        var blocks: [UInt8] = []
        if !pax.isEmpty {
            let records = paxRecords(pax)
            blocks += ustar(
                name: "PaxHeaders/" + String(decoding: entry.name.utf8.suffix(80), as: UTF8.self), prefix: "", type: .paxExtended, mode: 0o644,
                size: UInt64(records.count), mtime: entry.mtime, link: "")
            blocks += records
            blocks += padding(records.count)
        }
        blocks += ustar(
            name: name, prefix: prefix, type: entry.type, mode: entry.mode, size: min(entry.size, maxOctalSize), mtime: entry.mtime, link: link)
        return blocks
    }

    /// Splits a long name at a slash into ustar's 155-byte prefix and 100-byte name.
    static func splitForUstar(_ name: String) -> (String, String)? {
        let bytes = Array(name.utf8)
        guard bytes.count <= 256 else { return nil }
        for index in stride(from: min(bytes.count - 1, 155), through: 1, by: -1) where bytes[index] == UInt8(ascii: "/") {
            let prefix = bytes[..<index]
            let rest = bytes[(index + 1)...]
            if rest.count <= 100, !rest.isEmpty {
                return (String(decoding: prefix, as: UTF8.self), String(decoding: rest, as: UTF8.self))
            }
        }
        return nil
    }

    /// pax records, `"<length> <key>=<value>\n"`, where the length counts itself.
    static func paxRecords(_ pairs: [(String, String)]) -> [UInt8] {
        var out: [UInt8] = []
        for (key, value) in pairs {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count + 1
            while String(length).utf8.count + body.utf8.count != length {
                length = String(length).utf8.count + body.utf8.count
            }
            out += Array("\(length)\(body)".utf8)
        }
        return out
    }

    static func ustar(name: String, prefix: String, type: EntryType, mode: UInt32, size: UInt64, mtime: Date, link: String) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: blockSize)
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() {
                block[offset + index] = byte
            }
        }
        func octal(_ value: UInt64, at offset: Int, length: Int) {
            // Zero-padded digits and a NUL, as Go and GNU tar write them.
            let digits = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(length - 1 - digits.count, 0)) + digits
            put(padded, at: offset, length: length - 1)
        }
        put(name, at: 0, length: 100)
        octal(UInt64(mode & 0o7777), at: 100, length: 8)
        octal(0, at: 108, length: 8)
        octal(0, at: 116, length: 8)
        octal(size, at: 124, length: 12)
        octal(UInt64(max(mtime.timeIntervalSince1970, 0)), at: 136, length: 12)
        block[156] = type.rawValue
        put(link, at: 157, length: 100)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put(prefix, at: 345, length: 155)
        // The checksum is summed with its own field as spaces.
        for index in 148..<156 { block[index] = UInt8(ascii: " ") }
        let sum = block.reduce(0) { $0 + Int($1) }
        let digits = String(sum, radix: 8)
        put(String(repeating: "0", count: max(6 - digits.count, 0)) + digits, at: 148, length: 6)
        block[154] = 0
        block[155] = UInt8(ascii: " ")
        return block
    }

    static func padding(_ size: Int) -> [UInt8] {
        let remainder = size % blockSize
        return remainder == 0 ? [] : [UInt8](repeating: 0, count: blockSize - remainder)
    }

    /// The two zero blocks that end an archive.
    static var end: [UInt8] { [UInt8](repeating: 0, count: blockSize * 2) }
}

/// Writes a file or directory on the host as a tar, named `name` and `name/…`, as dockerd
/// writes the path an archive `GET` asks for.
struct DockerTarWriter {
    /// What the root entry says about itself: the container's own stat, when there is one,
    /// since a copy out of the container does not keep a single file's mode or time.
    var rootStat: DockerPathStat?

    /// Writes the archive to `write`, a chunk at a time, each written before the next is read.
    func write(_ root: URL, as name: String, to write: (ByteBuffer) async throws -> Void) async throws {
        let rootPath = root.path(percentEncoded: false)
        try await entry(at: rootPath, name: name, isRoot: true, to: write)
        var info = stat()
        if lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            try await directory(rootPath, name: name, to: write)
        }
        try await write(ByteBuffer(bytes: DockerTar.end))
    }

    private func directory(_ path: String, name: String, to write: (ByteBuffer) async throws -> Void) async throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        for child in children {
            let childPath = path + "/" + child
            let childName = name + "/" + child
            try await entry(at: childPath, name: childName, isRoot: false, to: write)
            var info = stat()
            if lstat(childPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                try await directory(childPath, name: childName, to: write)
            }
        }
    }

    private func entry(at path: String, name: String, isRoot: Bool, to write: (ByteBuffer) async throws -> Void) async throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var mode = UInt32(info.st_mode) & 0o7777
        var mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if isRoot, let rootStat {
            mode = rootStat.mode & 0o777 | DockerPathStat.posixSpecialBits(rootStat.mode)
            mtime = rootStat.mtime
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try await write(ByteBuffer(bytes: DockerTar.header(.init(name: name + "/", type: .directory, mode: mode, mtime: mtime))))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            try await write(ByteBuffer(bytes: DockerTar.header(.init(name: name, type: .symlink, mode: mode, mtime: mtime, linkTarget: target))))
        case S_IFREG:
            let size = UInt64(info.st_size)
            try await write(ByteBuffer(bytes: DockerTar.header(.init(name: name, type: .file, mode: mode, size: size, mtime: mtime))))
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var left = size
            while left > 0 {
                let want = Int(min(left, UInt64(DockerLogFile.chunkSize)))
                var chunk = try handle.read(upToCount: want) ?? Data()
                if chunk.isEmpty {
                    // The file shrank under the copy: the header promised more, so zeros.
                    chunk = Data(count: want)
                }
                left -= UInt64(chunk.count)
                try await write(ByteBuffer(bytes: chunk))
            }
            let padding = DockerTar.padding(Int(size % UInt64(DockerTar.blockSize)))
            if !padding.isEmpty { try await write(ByteBuffer(bytes: padding)) }
        default:
            // Sockets, pipes and devices have no content to copy.
            break
        }
    }
}

/// Why an uploaded archive was refused.
struct DockerTarRejection: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What an extraction left at the top of its root: the names `copyIn` takes one by one.
struct DockerExtractedEntry: Equatable {
    let name: String
    let isDirectory: Bool
    /// The mode the archive gave it, for a file.
    let mode: UInt32
}

/// Unpacks an uploaded tar into a fresh directory, refusing anything that could reach outside
/// it.
///
/// Each entry's name is checked before anything is written for it: an absolute name, a `..`
/// component, a name that passes through a symlink the archive made, a symlink whose target is
/// absolute or climbs out of the root, a hard link to anything but a file already unpacked, a
/// device or pipe, and anything past the size or entry bounds are each refused, and the whole
/// upload with them. Files are created without following links, so an entry cannot write
/// through one either.
struct DockerTarExtractor {
    var maxBytes: Int
    var maxEntries: Int
    /// The most a pax or GNU long-name header may hold.
    var maxHeaderBytes = 1 << 20

    /// Unpacks `archive` into `root`, which must exist and be empty.
    func extract(_ archive: URL, into root: URL) throws -> [DockerExtractedEntry] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var reader = BlockReader(handle: handle)
        let rootPath = root.path(percentEncoded: false)
        var state = State()
        var paxPath: String?
        var paxLink: String?
        var paxSize: UInt64?
        var entries = 0

        while true {
            guard let block = try reader.block() else { break }
            if block.allSatisfy({ $0 == 0 }) {
                // The end: one zero block, normally followed by another.
                break
            }
            guard Self.checksumMatches(block) else { throw DockerTarRejection(message: "invalid tar header: checksum mismatch") }
            entries += 1
            guard entries <= maxEntries else { throw DockerTarRejection(message: "the archive has more than \(maxEntries) entries") }
            let typeByte = block[156]
            var size = try Self.number(block[124..<136])
            let type = typeByte == 0 ? DockerTar.EntryType.file : DockerTar.EntryType(rawValue: typeByte)

            switch type {
            case .paxExtended, .paxGlobal, .gnuLongName, .gnuLongLink:
                guard size <= UInt64(maxHeaderBytes) else { throw DockerTarRejection(message: "the archive has an oversized extended header") }
                let data = try reader.read(Int(size))
                switch type {
                case .paxExtended:
                    let records = try Self.paxRecords(data)
                    paxPath = records["path"] ?? paxPath
                    paxLink = records["linkpath"] ?? paxLink
                    if let text = records["size"] {
                        guard let value = UInt64(text) else { throw DockerTarRejection(message: "invalid size in an extended header") }
                        paxSize = value
                    }
                case .gnuLongName:
                    paxPath = Self.string(data[...])
                case .gnuLongLink:
                    paxLink = Self.string(data[...])
                default:
                    break
                }
                continue
            default:
                break
            }

            if let paxSize { size = paxSize }
            var name = paxPath ?? Self.ustarName(block)
            let link = paxLink ?? Self.string(block[157..<257])
            paxPath = nil
            paxLink = nil
            paxSize = nil
            let mode = UInt32(truncatingIfNeeded: try Self.number(block[100..<108])) & 0o7777

            guard let type else { throw DockerTarRejection(message: "unsupported entry type '\(Character(UnicodeScalar(typeByte)))' for \(name)") }
            if type == .directory, name.hasSuffix("/") { name.removeLast() }
            let components = try Self.components(name)
            guard !components.isEmpty else {
                // The archive's own root, `./`.
                try reader.skip(size)
                continue
            }
            try state.checkParents(components)
            let relative = components.joined(separator: "/")
            let path = rootPath + "/" + relative

            switch type {
            case .directory:
                try state.makeParents(components.dropLast(), under: rootPath)
                try state.makeDirectory(path, relative: relative, mode: mode)
                try reader.skip(size)
            case .file, .contiguous:
                guard size <= UInt64(maxBytes - state.bytes) else {
                    throw DockerTarRejection(message: "the archive holds more than \(maxBytes) bytes")
                }
                try state.makeParents(components.dropLast(), under: rootPath)
                try state.writeFile(path, relative: relative, mode: mode, size: size, from: &reader)
            case .symlink:
                guard Self.linkStaysInside(link, from: components) else {
                    throw DockerTarRejection(message: "the symlink \(relative) points outside the archive: \(link)")
                }
                try state.makeParents(components.dropLast(), under: rootPath)
                try state.makeSymlink(path, relative: relative, target: link)
                try reader.skip(size)
            case .hardLink:
                let targetComponents = try Self.components(link)
                let target = targetComponents.joined(separator: "/")
                guard state.files.contains(target) else {
                    throw DockerTarRejection(message: "the hard link \(relative) points to \(link), which is not a file in the archive")
                }
                try state.makeParents(components.dropLast(), under: rootPath)
                try state.makeHardLink(path, relative: relative, target: rootPath + "/" + target)
                try reader.skip(size)
            default:
                throw DockerTarRejection(message: "unsupported entry type for \(relative): only files, directories and links can be copied")
            }
            state.top(components[0], isDirectory: components.count > 1 || type == .directory, mode: components.count == 1 ? mode : nil)
        }
        return state.topLevel
    }

    /// The path components of an entry name, refused when absolute or climbing.
    static func components(_ name: String) throws -> [String] {
        guard !name.hasPrefix("/") else { throw DockerTarRejection(message: "the archive has an absolute path: \(name)") }
        var parts: [String] = []
        for part in name.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            guard part != ".." else { throw DockerTarRejection(message: "the archive has a path that leaves it: \(name)") }
            parts.append(String(part))
        }
        return parts
    }

    /// Whether a symlink at `components` with target `link` resolves inside the root, by its
    /// words alone. An absolute target is refused: on the host it would point at the host.
    static func linkStaysInside(_ link: String, from components: [String]) -> Bool {
        guard !link.isEmpty, !link.hasPrefix("/") else { return false }
        var resolved = Array(components.dropLast())
        for part in link.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !resolved.isEmpty else { return false }
                resolved.removeLast()
            default: resolved.append(String(part))
            }
        }
        return true
    }

    static func checksumMatches(_ block: [UInt8]) -> Bool {
        guard let stored = try? number(block[148..<156]) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in block.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return UInt64(unsigned) == stored || Int64(signed) == Int64(bitPattern: stored)
    }

    /// A numeric field: octal digits, or GNU's base-256 with the top bit of the first byte set.
    static func number(_ field: ArraySlice<UInt8>) throws -> UInt64 {
        if let first = field.first, first & 0x80 != 0 {
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in field.dropFirst() {
                guard value <= UInt64.max >> 8 else { throw DockerTarRejection(message: "invalid number in a tar header") }
                value = value << 8 | UInt64(byte)
            }
            return value
        }
        var value: UInt64 = 0
        var seen = false
        for byte in field {
            if byte == 0 || byte == UInt8(ascii: " ") {
                if seen { break }
                continue
            }
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte), value <= UInt64.max >> 3 else {
                throw DockerTarRejection(message: "invalid number in a tar header")
            }
            seen = true
            value = value << 3 | UInt64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    static func string(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func ustarName(_ block: [UInt8]) -> String {
        let name = string(block[0..<100])
        let magic = block[257..<262]
        let prefix = Array(magic) == Array("ustar".utf8) ? string(block[345..<500]) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    static func paxRecords(_ data: [UInt8]) throws -> [String: String] {
        var records: [String: String] = [:]
        var rest = data[...]
        while !rest.isEmpty {
            guard let space = rest.firstIndex(of: UInt8(ascii: " ")),
                let length = Int(String(decoding: rest[rest.startIndex..<space], as: UTF8.self)), length > 0, length <= rest.count
            else { throw DockerTarRejection(message: "invalid extended header") }
            let record = rest[(space + 1)..<(rest.startIndex + length)]
            rest = rest[(rest.startIndex + length)...]
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")) else { throw DockerTarRejection(message: "invalid extended header") }
            let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
            var value = record[(equals + 1)...]
            if value.last == UInt8(ascii: "\n") { value = value.dropLast() }
            records[key] = String(decoding: value, as: UTF8.self)
        }
        return records
    }

    /// What has been unpacked so far.
    struct State {
        var bytes = 0
        var directories: Set<String> = []
        var files: Set<String> = []
        var symlinks: Set<String> = []
        var topLevel: [DockerExtractedEntry] = []

        /// Refuses an entry whose path goes through a symlink or a file the archive made.
        func checkParents(_ components: [String]) throws {
            var prefix = ""
            for part in components.dropLast() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                if symlinks.contains(prefix) || files.contains(prefix) {
                    throw DockerTarRejection(message: "the archive writes through \(prefix), which is not a directory")
                }
            }
        }

        mutating func makeParents(_ components: ArraySlice<String>, under root: String) throws {
            var relative = ""
            for part in components {
                relative = relative.isEmpty ? part : relative + "/" + part
                guard !directories.contains(relative) else { continue }
                try makeDirectory(root + "/" + relative, relative: relative, mode: 0o755)
            }
        }

        mutating func makeDirectory(_ path: String, relative: String, mode: UInt32) throws {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw DockerTarRejection(message: "the archive makes \(relative) a directory after making it something else")
                }
            } else if mkdir(path, 0o700) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Writable by this service whatever the archive says, so what follows can go in.
            chmod(path, mode_t(mode | 0o700))
            directories.insert(relative)
        }

        mutating func writeFile(_ path: String, relative: String, mode: UInt32, size: UInt64, from reader: inout BlockReader) throws {
            guard !directories.contains(relative), !symlinks.contains(relative) else {
                throw DockerTarRejection(message: "the archive makes \(relative) a file after making it something else")
            }
            // O_NOFOLLOW: never through a link, whatever made it.
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw DockerTarRejection(message: "could not write \(relative): \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            try reader.copy(size, to: fd)
            fchmod(fd, mode_t(mode))
            bytes += Int(size)
            files.insert(relative)
        }

        mutating func makeSymlink(_ path: String, relative: String, target: String) throws {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFDIR else {
                    throw DockerTarRejection(message: "the archive makes \(relative) a symlink after making it a directory")
                }
                unlink(path)
            }
            guard symlink(target, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            files.remove(relative)
            symlinks.insert(relative)
        }

        mutating func makeHardLink(_ path: String, relative: String, target: String) throws {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFDIR else {
                    throw DockerTarRejection(message: "the archive makes \(relative) a link after making it a directory")
                }
                unlink(path)
            }
            guard link(target, path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            symlinks.remove(relative)
            files.insert(relative)
        }

        /// Notes a name at the top of the root. `mode` is nil for an entry under it, which only
        /// says that the name is a directory.
        mutating func top(_ name: String, isDirectory: Bool, mode: UInt32?) {
            if let index = topLevel.firstIndex(where: { $0.name == name }) {
                topLevel[index] = DockerExtractedEntry(name: name, isDirectory: isDirectory, mode: mode ?? topLevel[index].mode)
            } else {
                topLevel.append(DockerExtractedEntry(name: name, isDirectory: isDirectory, mode: mode ?? 0o755))
            }
        }
    }

    /// Reads an archive a block at a time, through a bounded buffer.
    struct BlockReader {
        let handle: FileHandle

        /// The next block, or nil at the end of the file.
        mutating func block() throws -> [UInt8]? {
            let data = try handle.read(upToCount: DockerTar.blockSize) ?? Data()
            if data.isEmpty { return nil }
            guard data.count == DockerTar.blockSize else { throw DockerTarRejection(message: "the archive ends in the middle of a header") }
            return Array(data)
        }

        /// `size` bytes of content, and the padding after them.
        mutating func read(_ size: Int) throws -> [UInt8] {
            let data = try handle.read(upToCount: size) ?? Data()
            guard data.count == size else { throw DockerTarRejection(message: "the archive ends in the middle of an entry") }
            try skipPadding(UInt64(size))
            return Array(data)
        }

        mutating func skip(_ size: UInt64) throws {
            guard size > 0 else { return }
            let total = size + UInt64(DockerTar.padding(Int(size % UInt64(DockerTar.blockSize))).count)
            let offset = try handle.offset()
            try handle.seek(toOffset: offset + total)
        }

        mutating func copy(_ size: UInt64, to fd: Int32) throws {
            var left = size
            while left > 0 {
                let data = try handle.read(upToCount: Int(min(left, UInt64(DockerLogFile.chunkSize)))) ?? Data()
                guard !data.isEmpty else { throw DockerTarRejection(message: "the archive ends in the middle of an entry") }
                try data.withUnsafeBytes { bytes in
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        written += count
                    }
                }
                left -= UInt64(data.count)
            }
            try skipPadding(size)
        }

        private mutating func skipPadding(_ size: UInt64) throws {
            let padding = DockerTar.padding(Int(size % UInt64(DockerTar.blockSize))).count
            guard padding > 0 else { return }
            let data = try handle.read(upToCount: padding) ?? Data()
            guard data.count == padding else { throw DockerTarRejection(message: "the archive ends in the middle of an entry") }
        }
    }
}
