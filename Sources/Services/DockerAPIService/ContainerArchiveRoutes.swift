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
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A path in a container as `X-Docker-Container-Path-Stat` describes it.
public struct DockerPathStat: Sendable, Equatable {
    public static let headerName = "X-Docker-Container-Path-Stat"

    // Go's `os.FileMode` type bits, which the header carries instead of POSIX's: the CLI asks
    // `IsDir()` and looks for `ModeSymlink` there.
    static let goDirectory: UInt32 = 1 << 31
    static let goSymlink: UInt32 = 1 << 27
    static let goDevice: UInt32 = 1 << 26
    static let goNamedPipe: UInt32 = 1 << 25
    static let goSocket: UInt32 = 1 << 24
    static let goSetuid: UInt32 = 1 << 23
    static let goSetgid: UInt32 = 1 << 22
    static let goCharDevice: UInt32 = 1 << 21
    static let goSticky: UInt32 = 1 << 20

    public var name: String
    public var size: Int64
    /// Go's `os.FileMode`: the permission bits and Go's own type and special bits.
    public var mode: UInt32
    public var mtime: Date
    public var linkTarget: String

    public init(name: String, size: Int64, mode: UInt32, mtime: Date, linkTarget: String = "") {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
        self.linkTarget = linkTarget
    }

    public var isDirectory: Bool { mode & Self.goDirectory != 0 }
    public var isSymlink: Bool { mode & Self.goSymlink != 0 }

    /// Go's `os.FileMode` for a POSIX `st_mode`.
    public static func goMode(posix: UInt32) -> UInt32 {
        var mode = posix & 0o777
        switch posix & UInt32(S_IFMT) {
        case UInt32(S_IFDIR): mode |= goDirectory
        case UInt32(S_IFLNK): mode |= goSymlink
        case UInt32(S_IFIFO): mode |= goNamedPipe
        case UInt32(S_IFSOCK): mode |= goSocket
        case UInt32(S_IFBLK): mode |= goDevice
        case UInt32(S_IFCHR): mode |= goDevice | goCharDevice
        default: break
        }
        if posix & UInt32(S_ISUID) != 0 { mode |= goSetuid }
        if posix & UInt32(S_ISGID) != 0 { mode |= goSetgid }
        if posix & UInt32(S_ISVTX) != 0 { mode |= goSticky }
        return mode
    }

    /// The setuid, setgid and sticky bits of a Go mode, as POSIX has them.
    static func posixSpecialBits(_ mode: UInt32) -> UInt32 {
        (mode & goSetuid != 0 ? UInt32(S_ISUID) : 0) | (mode & goSetgid != 0 ? UInt32(S_ISGID) : 0) | (mode & goSticky != 0 ? UInt32(S_ISVTX) : 0)
    }

    /// The name dockerd gives a path: its last component, `/` for the root.
    public static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    struct Body: Encodable {
        let name: String
        let size: Int64
        let mode: UInt32
        let mtime: String
        let linkTarget: String
    }

    /// The header's value: the JSON, in standard base64.
    public var headerValue: String {
        let body = Body(name: name, size: size, mode: mode, mtime: ContainerViewMapper.timestamp(mtime), linkTarget: linkTarget)
        // Encoding strings and numbers cannot fail.
        return ((try? DockerJSON.encoder.encode(body)) ?? Data("{}".utf8)).base64EncodedString()
    }

    /// A path on the host, as a stat of it.
    static func host(_ path: String, name: String) throws -> DockerPathStat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let target = info.st_mode & S_IFMT == S_IFLNK ? (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "" : ""
        return DockerPathStat(
            name: name, size: Int64(info.st_size), mode: goMode(posix: UInt32(info.st_mode)),
            mtime: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), linkTarget: target)
    }

    /// Reads `stat -c '%f %s %Y'`: the raw mode in hex, the size and the modification time.
    static func parse(statOutput: String, name: String) -> DockerPathStat? {
        let fields = statOutput.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, let raw = UInt32(fields[0], radix: 16), let size = Int64(fields[1]), let seconds = Int64(fields[2]) else {
            return nil
        }
        return DockerPathStat(name: name, size: size, mode: goMode(posix: raw), mtime: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// `GET`, `HEAD` and `PUT /containers/{id}/archive`, which `docker cp` drives.
///
/// The engine copies files in and out of a running container; a path's mode, size, time and
/// link target come from running `stat` (and `readlink`) inside it, since a copy out keeps
/// neither a file's mode nor its time. An image without `stat` still copies: `HEAD` and `GET`
/// then describe the copy instead, and an upload goes in without checking where it lands.
extension ContainerToolRoutes.Routes {
    static func archivePath(_ request: DockerRequest) throws(DockerAPIError) -> String {
        guard let path = request.query("path"), !path.isEmpty else {
            throw .badRequest("bad parameter: path cannot be empty")
        }
        // dockerd reads a relative path from the root.
        return path.hasPrefix("/") ? path : "/" + path
    }

    static func fileNotFound(_ path: String, _ reference: String) -> DockerAPIError {
        ContainerPathArchive.notFound(path, in: reference)
    }

    /// Looks at `path` in the container with `stat`, following a final symlink when `follow`.
    func probe(_ container: DockerContainer, _ path: String, follow: Bool) async throws -> DockerPathProbe {
        try await ContainerPathArchive.probe(engine, in: container.snapshot, path, follow: follow)
    }

    /// A directory of its own in the scratch directory, for one request's copies.
    func makeScratch() throws -> URL {
        try ContainerPathArchive.makeScratch(engine)
    }

    /// Copies `path` out of the container into `destination`, saying "not found" in dockerd's
    /// words when the engine's copy could not find it.
    func copyOut(_ container: DockerContainer, _ path: String, to destination: URL, reference: String, requester: String?) async throws {
        do {
            try await engine.copyOut(container.snapshot, source: path, destination: destination, requester: requester)
        } catch {
            let text = "\(error)"
            if text.contains("No such file") || text.contains("not found") || text.contains("notFound") {
                throw Self.fileNotFound(path, reference)
            }
            throw DockerAPIError.internalError("could not copy \(path) out of container \(reference): \(DockerContainerProcesses.message(error))")
        }
    }

    /// `GET /containers/{id}/archive?path=`: a tar of the path, named for its last component,
    /// with its stat in the header. `HEAD`: the header alone.
    func archive(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let path = try Self.archivePath(request)
        let container = try await running(reference)
        let probe = try await probe(container, path, follow: false)
        if probe == .notFound { throw Self.fileNotFound(path, reference) }
        let name = DockerPathStat.baseName(path)
        var known: DockerPathStat?
        if case .found(let stat) = probe { known = stat }

        if request.method == .HEAD {
            let stat: DockerPathStat
            if let known {
                stat = known
            } else if path.split(separator: "/").isEmpty {
                stat = DockerPathStat(name: "/", size: 0, mode: DockerPathStat.goDirectory | 0o755, mtime: Date(timeIntervalSince1970: 0))
            } else {
                // No `stat` in the image: copy the path out and look at the copy.
                let scratch = try makeScratch()
                defer { try? FileManager.default.removeItem(at: scratch) }
                let copy = scratch.appending(path: "copy")
                try await copyOut(container, path, to: copy, reference: reference, requester: request.peer?.requester)
                stat = try DockerPathStat.host(copy.path(percentEncoded: false), name: name)
            }
            var headers = HTTPHeaders()
            headers.add(name: DockerPathStat.headerName, value: stat.headerValue)
            return .data(status: .ok, contentType: "application/x-tar", body: ByteBuffer(), headers: headers)
        }

        // The root and a trailing `/.` are archived as `.`, the way dockerd names them.
        let entryName = ContainerPathArchive.entryName(for: path)
        let scratch = try makeScratch()
        let stat: DockerPathStat
        let copy = scratch.appending(path: "copy")
        do {
            stat = try await ContainerPathArchive.stage(path, known: known, at: copy) {
                try await copyOut(container, path, to: copy, reference: reference, requester: request.peer?.requester)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        var headers = HTTPHeaders()
        headers.add(name: DockerPathStat.headerName, value: stat.headerValue)
        let writer = DockerTarWriter(rootStat: known)
        return .stream(status: .ok, contentType: "application/x-tar", headers: headers) { output in
            defer { try? FileManager.default.removeItem(at: scratch) }
            try await writer.write(copy, as: entryName) { try await output.write($0) }
        }
    }

    /// `PUT /containers/{id}/archive?path=&noOverwriteDirNonDir=`: unpacks the uploaded tar
    /// into the directory `path`.
    ///
    /// The body is spooled to disk under its own bound, unpacked through `DockerTarExtractor`'s
    /// checks, and each name at the top of it is copied in. The archive must be uncompressed, as
    /// the CLI sends it.
    ///
    /// A container that is not running has no filesystem to copy into until its VM is up: what
    /// it is sent is unpacked and checked now, and copied in at its next start
    /// (`DockerPendingCopies`). Its paths cannot be looked at before then, so `path` is not
    /// checked to be a directory and `noOverwriteDirNonDir` is not applied; the copy makes a
    /// missing `path`. An upload that finds a start has taken the queue before it is copied in
    /// here, into the container that start is starting, the same way.
    func extract(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let path = try Self.archivePath(request)
        let noOverwriteDirNonDir = try request.bool("noOverwriteDirNonDir")
        let container = try await find(reference)
        let heldForStart = !ContainerViewMapper.isRunning(container.snapshot)
        if heldForStart {
            // An engine from before it could copy before a start reaches a container's
            // filesystem only while it runs.
            guard streams.copies.queue != nil, await engine.supportsCopyBeforeStart() else {
                throw DockerAPIError.conflict(
                    "container \(container.dockerID) is not running: SiliconShip copies files into a running container only, so start it first")
            }
        } else {
            switch try await probe(container, path, follow: true) {
            case .notFound:
                throw Self.fileNotFound(path, reference)
            case .found(let stat) where !stat.isDirectory:
                throw DockerAPIError.badRequest("extraction point is not a directory")
            default:
                break
            }
        }
        guard let archive = request.bodyFile else {
            guard request.body.readableBytes == 0 else { throw DockerAPIError.internalError("the archive was not stored") }
            return .empty(.ok)
        }
        try Self.refuseCompressed(archive)

        // What is held is written where it is held, so that it outlasts this service.
        let scratch = try heldForStart ? streams.copies.stage() : makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = PendingCopyQueue.root(of: scratch)
        guard mkdir(root.path(percentEncoded: false), 0o700) == 0 else {
            throw DockerAPIError.internalError("could not make a directory for the archive")
        }
        let extractor = DockerTarExtractor(maxBytes: options.maxUploadBytes, maxEntries: options.maxUploadEntries)
        let entries: [DockerExtractedEntry]
        do {
            entries = try await NIOThreadPool.singleton.runIfActive { try extractor.extract(archive, into: root) }
        } catch let rejection as DockerTarRejection {
            throw DockerAPIError.badRequest(rejection.message)
        }

        if heldForStart {
            let record = PendingCopyQueue.Record(
                destination: path, entries: entries.map { PendingCopyQueue.Entry(name: $0.name, isDirectory: $0.isDirectory, mode: $0.mode) },
                requester: request.peer?.requester)
            // Once held, the staged directory is no longer where it was, and this removes nothing.
            switch try await streams.copies.hold(scratch, record: record, engineID: container.engineID) {
            case .held, .takenByStart:
                return .empty(.ok)
            case .takenBack(let upload):
                // Started meanwhile, past the point of copying in what is held: into it now.
                defer { try? FileManager.default.removeItem(at: upload) }
                try await copyIn(
                    entries, from: PendingCopyQueue.root(of: upload), into: path, of: container, reference: reference, requester: request.peer?.requester)
                return .empty(.ok)
            }
        }
        if noOverwriteDirNonDir {
            for entry in entries {
                let target = (path.hasSuffix("/") ? path : path + "/") + entry.name
                guard case .found(let existing) = try await probe(container, target, follow: false) else { continue }
                if existing.isDirectory && !entry.isDirectory {
                    throw DockerAPIError.internalError("cannot overwrite directory \"\(target)\" with non-directory \"\(entry.name)\"")
                }
                if !existing.isDirectory && entry.isDirectory {
                    throw DockerAPIError.internalError("cannot overwrite non-directory \"\(target)\" with directory \"\(entry.name)\"")
                }
            }
        }
        try await copyIn(entries, from: root, into: path, of: container, reference: reference, requester: request.peer?.requester)
        return .empty(.ok)
    }

    /// Copies each of `entries`, unpacked in `root`, into the directory `path` in `container`.
    func copyIn(
        _ entries: [DockerExtractedEntry], from root: URL, into path: String, of container: DockerContainer, reference: String, requester: String?
    ) async throws {
        for entry in entries {
            do {
                try await engine.copyIn(container.snapshot, source: root.appending(path: entry.name), destination: path, mode: entry.mode, requester: requester)
            } catch {
                throw DockerAPIError.internalError("could not copy \(entry.name) into \(path) in container \(reference): \(DockerContainerProcesses.message(error))")
            }
        }
    }

    /// Refuses an archive that starts like gzip, bzip2, xz or zstd: dockerd takes them, this
    /// service does not, and the CLI never sends one.
    static func refuseCompressed(_ archive: URL) throws {
        try ContainerPathArchive.refuseCompressed(archive)
    }
}
