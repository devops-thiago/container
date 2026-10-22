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

import ContainerResource
import ContainerizationArchive
import ContainerizationError
import Foundation
import SystemPackage

/// The owner `docker cp -a` (`copyUIDGID`) gives what it copies in: the container's user,
/// looked up in the container's own `/etc/passwd` and `/etc/group` as dockerd looks it up.
///
/// - A container without a user gets nil: everything keeps the owner its source names.
/// - `name` or `uid`: that user's uid and primary group; a uid with no entry gets gid 0.
/// - `user:group`: the group by name or gid; an empty side is 0 (`:33` is `0:33`).
/// - A name with no entry is refused.
enum CopyUser {
    /// Whether finding `user`'s owner needs the container's user and group files.
    static func needsLookup(_ user: ProcessConfiguration.User) -> Bool {
        guard case .raw(let text) = user else { return false }
        return !text.isEmpty
    }

    static func owner(of user: ProcessConfiguration.User, passwd: String?, group: String?) throws -> CopyOwner? {
        let text: String
        switch user {
        case .id(0, 0):
            // What a container gets when no user is named.
            return nil
        case .id(let uid, let gid):
            return CopyOwner(uid: uid, gid: gid)
        case .raw(let raw):
            text = raw
        }
        guard !text.isEmpty else { return nil }
        let (userPart, groupPart) = split(text)
        var uid: UInt32 = 0
        var gid: UInt32 = 0
        if !userPart.isEmpty {
            let users = entries(passwd)
            if let id = numericID(userPart) {
                uid = id
                gid = users.first { UInt32($0[safe: 2] ?? "") == id }.flatMap { UInt32($0[safe: 3] ?? "") } ?? 0
            } else {
                guard let entry = users.first(where: { $0.first == userPart }), let id = UInt32(entry[safe: 2] ?? ""),
                    let primary = UInt32(entry[safe: 3] ?? "")
                else {
                    throw ContainerizationError(.invalidArgument, message: "failed to look up user \"\(userPart)\" in container")
                }
                uid = id
                gid = primary
            }
        }
        if !groupPart.isEmpty {
            if let id = numericID(groupPart) {
                gid = id
            } else {
                guard let entry = entries(group).first(where: { $0.first == groupPart }), let id = UInt32(entry[safe: 2] ?? "") else {
                    throw ContainerizationError(.invalidArgument, message: "failed to look up group \"\(groupPart)\" in container")
                }
                gid = id
            }
        }
        return CopyOwner(uid: uid, gid: gid)
    }

    /// `user`'s owner, reading the container's user and group files under `rootfs` through
    /// `agent` when it names anyone. A file that cannot be read is taken as empty, as dockerd
    /// takes one that is missing.
    static func owner(of user: ProcessConfiguration.User, rootfs: String, agent: some GuestCopyAgent) async throws -> CopyOwner? {
        guard needsLookup(user) else { return try owner(of: user, passwd: nil, group: nil) }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "copy-user-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func read(_ path: String) async -> String? {
            let copy = scratch.appending(path: FilePath(path).lastComponent?.string ?? "file")
            guard (try? await agent.copyOut(root: rootfs, path: path, to: copy)) != nil else { return nil }
            return try? String(contentsOf: copy, encoding: .utf8)
        }
        return try owner(of: user, passwd: await read("/etc/passwd"), group: await read("/etc/group"))
    }

    /// `user[:group]`, split at the first colon.
    static func split(_ text: String) -> (String, String) {
        guard let colon = text.firstIndex(of: ":") else { return (text, "") }
        return (String(text[..<colon]), String(text[text.index(after: colon)...]))
    }

    /// An id as dockerd takes one: a number that fits a positive 32-bit signed integer.
    /// Anything else is a name.
    static func numericID(_ text: String) -> UInt32? {
        guard let value = UInt32(text), value <= UInt32(Int32.max) else { return nil }
        return value
    }

    /// The colon-separated fields of each entry in a passwd or group file.
    static func entries(_ file: String?) -> [[String]] {
        (file ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The archive a copy into a container is sent as. The VM's agent unpacks it at the
/// destination and gives each entry the owner the archive names, so the owner is decided here:
/// `owner` when the copy asks for one (`copyUIDGID`), else what was recorded for the file when
/// it was staged from an archive (`CopyOwner.recorded(at:)`), else the file's owner on the host,
/// as the Docker CLI puts it in the archive it sends.
enum CopyArchive {
    /// Writes `source` to `fd` as a gzipped pax archive: a directory as `./` and everything in
    /// it, a file as the one entry `name` with `mode` (0644 when 0).
    static func write(_ source: URL, isDirectory: Bool, name: String, mode: UInt32, owner: CopyOwner?, to fd: Int32) throws {
        let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
        try writer.open(fileDescriptor: fd)
        let path = FilePath(source.path(percentEncoded: false))
        if isDirectory {
            try directory(path, owner: owner, to: writer)
        } else {
            var info = stat()
            guard stat(path.string, &info) == 0 else { throw failure("stat", path) }
            let entry = makeEntry(path.string, info: info, owner: owner)
            entry.path = name
            entry.fileType = .regular
            entry.permissions = mode_t(mode > 0 ? mode : 0o644)
            entry.size = Int64(info.st_size)
            try contents(of: path.string, entry: entry, to: writer)
        }
        try writer.finishEncoding()
    }

    /// The owner an entry for the file at `path` gets.
    static func owner(of path: String, info: stat, override: CopyOwner?) -> CopyOwner {
        override ?? CopyOwner.recorded(at: path) ?? CopyOwner(uid: info.st_uid, gid: info.st_gid)
    }

    /// Everything under `root`, as containerization's `archiveDirectory` walks it: a leading
    /// `./`, then regular files, directories and the symlinks that stay inside `root`.
    private static func directory(_ root: FilePath, owner: CopyOwner?, to writer: ArchiveWriter) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: root.string) else { throw POSIXError(.ENOTDIR) }
        var info = stat()
        guard lstat(root.string, &info) == 0 else { throw failure("lstat", root) }
        let top = makeEntry(root.string, info: info, owner: owner)
        top.path = "./"
        top.size = 0
        top.fileType = .directory
        try writer.writeEntry(entry: top, data: nil)

        for case let relative as String in enumerator {
            let full = root.appending(relative)
            guard lstat(full.string, &info) == 0 else { throw failure("lstat", full) }
            let entry = makeEntry(full.string, info: info, owner: owner)
            entry.path = relative
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                entry.fileType = .regular
                entry.size = Int64(info.st_size)
                try contents(of: full.string, entry: entry, to: writer)
            case S_IFDIR:
                entry.fileType = .directory
                entry.size = 0
                try writer.writeEntry(entry: entry, data: nil)
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: full.string)
                let resolved = full.removingLastComponent().appending(target).lexicallyNormalized()
                guard resolved.starts(with: root) else { continue }
                entry.fileType = .symbolicLink
                entry.size = 0
                entry.symlinkTarget = target
                try writer.writeEntry(entry: entry, data: nil)
            default:
                continue
            }
        }
    }

    private static func makeEntry(_ path: String, info: stat, owner: CopyOwner?) -> WriteEntry {
        let entry = WriteEntry()
        let decided = Self.owner(of: path, info: info, override: owner)
        entry.owner = decided.uid
        entry.group = decided.gid
        entry.permissions = info.st_mode
        entry.creationDate = Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec))
        entry.contentAccessDate = Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec))
        entry.modificationDate = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        return entry
    }

    private static func contents(of path: String, entry: WriteEntry, to writer: ArchiveWriter) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open", FilePath(path)) }
        defer { close(fd) }
        let transaction = writer.makeTransactionWriter()
        try transaction.writeHeader(entry: entry)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: VminitdCopyAgent.chunkSize, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer.baseAddress, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw failure("read", FilePath(path)) }
            try transaction.writeChunk(data: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
        try transaction.finish()
    }

    private static func failure(_ call: String, _ path: FilePath) -> ContainerizationError {
        ContainerizationError(.internalError, message: "copyIn: \(call) failed for '\(path)': \(String(cString: strerror(errno)))")
    }
}
