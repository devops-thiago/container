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
import NIOPosix

/// What looking at a path in a container found.
package enum DockerPathProbe: Equatable, Sendable {
    case found(DockerPathStat)
    case notFound
    /// The container has no `stat` to look with.
    case unavailable
}

/// A container path as a tar archive, the way `docker cp` streams one: what the archive routes
/// serve, and what `container cp CTR:SRC -` writes to stdout and `container cp - CTR:DEST`
/// reads from stdin.
///
/// The engine's copies take paths on the host, so an archive is staged in the engine's scratch
/// directory (`EngineContainerTools.scratchDirectory()`) on its way, and removed after.
package enum ContainerPathArchive {
    /// The name of an archive's top entry, as dockerd names it: the path's last component,
    /// and `.` for the root or a path ending in `/.`.
    package static func entryName(for path: String) -> String {
        let name = DockerPathStat.baseName(path)
        return name == "/" ? "." : name
    }

    /// dockerd's error for a path a container does not have.
    package static func notFound(_ path: String, in reference: String) -> DockerAPIError {
        .notFound("Could not find the file \(path) in container \(reference)")
    }

    /// Looks at `path` in the container with `stat`, following a final symlink when `follow`.
    package static func probe(
        _ tools: some EngineContainerTools, in container: ContainerSnapshot, _ path: String, follow: Bool
    ) async throws -> DockerPathProbe {
        let name = DockerPathStat.baseName(path)
        let run: DockerCapturedRun
        do {
            run = try await DockerContainerCommand.run(tools, in: container, ["stat"] + (follow ? ["-L"] : []) + ["-c", DockerPathStat.statFormat, path])
        } catch is DockerContainerCommand.Unavailable {
            return .unavailable
        }
        if run.status == DockerContainerCommand.notFoundStatus, !run.reason.contains(path) {
            return .unavailable
        }
        guard run.status == 0 else {
            if run.reason.contains("No such file or directory") { return .notFound }
            throw DockerAPIError.internalError("stat \(path): \(run.reason.isEmpty ? "exit status \(run.status)" : run.reason)")
        }
        guard var stat = DockerPathStat.parse(statOutput: run.stdoutText, name: name) else {
            throw DockerAPIError.internalError("stat \(path): could not read its output")
        }
        if stat.isSymlink {
            let link = try? await DockerContainerCommand.run(tools, in: container, ["readlink", path])
            if let link, link.status == 0 {
                stat.linkTarget = link.stdoutText.trimmingCharacters(in: .newlines)
            }
        }
        return .found(stat)
    }

    /// The path a symlink at `path` resolves to, as the Docker CLI resolves it for `-L` and for
    /// a destination: a relative target from the link's directory, cleaned, keeping a trailing
    /// `/.` or `/` the path was given with (moby's `archive.GetRebaseName`).
    package static func resolve(_ path: String, linkTarget: String) -> String {
        // moby's `SplitPathDirEntry`: the directory of the cleaned path.
        let cleaned = clean(path)
        let parent = String(cleaned[...(cleaned.lastIndex(of: "/") ?? cleaned.startIndex)])
        var resolved = clean(linkTarget.hasPrefix("/") ? linkTarget : parent + linkTarget)
        if specifiesCurrentDirectory(path), !specifiesCurrentDirectory(resolved) {
            resolved += resolved.hasSuffix("/") ? "." : "/."
        }
        if path.hasSuffix("/"), !resolved.hasSuffix("/") {
            resolved += "/"
        }
        return resolved
    }

    static func specifiesCurrentDirectory(_ path: String) -> Bool {
        path == "." || path.hasSuffix("/.")
    }

    /// Go's `filepath.Clean` for an absolute path: no empty, `.` or `..` components.
    static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A directory of its own in the scratch directory, for one copy.
    package static func makeScratch(_ tools: some EngineContainerTools) throws -> URL {
        let directory = try tools.scratchDirectory().appending(path: "docker-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(directory.path(percentEncoded: false), 0o700) == 0 else {
            throw DockerAPIError.internalError("could not make a directory for the copy: \(String(cString: strerror(errno)))")
        }
        return directory
    }

    /// Puts what `path` is at `copy` on the host: the link itself when `known` says it is
    /// one, as dockerd archives a link and not what it points to, else `copyOut`'s copy.
    /// Returns the stat for the archive's top entry.
    package static func stage(
        _ path: String, known: DockerPathStat?, at copy: URL, copyOut: () async throws -> Void
    ) async throws -> DockerPathStat {
        if let known, known.isSymlink {
            guard symlink(known.linkTarget, copy.path(percentEncoded: false)) == 0 else {
                throw DockerAPIError.internalError("could not stage the link \(path)")
            }
        } else {
            try await copyOut()
        }
        return try known ?? DockerPathStat.host(copy.path(percentEncoded: false), name: DockerPathStat.baseName(path))
    }

    /// Writes `path` in `container` to `output` as the tar `docker cp CTR:SRC -` writes: one
    /// entry named for the path's last component, and for a directory everything in it under
    /// that name. `followLink` is `docker cp -L`: a symlink at `path` is archived as what it
    /// points to, under that target's name, as the Docker CLI streams it (it renames the
    /// entries only when it unpacks them itself).
    ///
    /// - Parameter reference: the container as the caller named it, for the errors.
    package static func write(
        _ tools: some EngineContainerTools, container: ContainerSnapshot, path: String, reference: String, followLink: Bool,
        requester: String?, to output: FileHandle
    ) async throws {
        var path = path
        var probe = try await probe(tools, in: container, path, follow: false)
        if followLink, case .found(let stat) = probe, stat.isSymlink {
            path = resolve(path, linkTarget: stat.linkTarget)
            probe = try await self.probe(tools, in: container, path, follow: false)
        }
        if probe == .notFound { throw notFound(path, in: reference) }
        var known: DockerPathStat?
        if case .found(let stat) = probe { known = stat }

        let scratch = try makeScratch(tools)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appending(path: "copy")
        _ = try await stage(path, known: known, at: copy) {
            do {
                try await tools.copyOut(container, source: path, destination: copy, requester: requester)
            } catch {
                let text = "\(error)"
                if text.contains("No such file") || text.contains("not found") || text.contains("notFound") {
                    throw notFound(path, in: reference)
                }
                throw error
            }
        }
        let writer = DockerTarWriter(rootStat: known)
        try await writer.write(copy, as: entryName(for: path)) { buffer in
            try output.write(contentsOf: Data(buffer.readableBytesView))
        }
    }

    /// Reads a tar from `input` and copies what it holds into the directory `path` in
    /// `container`, as `docker cp - CTR:DEST` does: `path` must be a directory, or a link to
    /// one, and an archive's own names and owners are kept. The archive is spooled and
    /// unpacked through `DockerTarExtractor`'s checks before anything is copied in.
    ///
    /// - Parameters:
    ///   - reference: the container as the caller named it, for the errors.
    ///   - copyUIDGID: `docker cp -a`: the container's user owns what is copied.
    package static func extract(
        _ tools: some EngineContainerTools, container: ContainerSnapshot, from input: FileHandle, into path: String, reference: String,
        copyUIDGID: Bool = false, requester: String?
    ) async throws {
        var destination = path
        var probe = try await probe(tools, in: container, path, follow: false)
        if case .found(let stat) = probe, stat.isSymlink {
            destination = resolve(path, linkTarget: stat.linkTarget)
            probe = try await self.probe(tools, in: container, destination, follow: true)
        }
        let isDirectory: Bool
        switch probe {
        case .found(let stat): isDirectory = stat.isDirectory
        case .unavailable: isDirectory = true
        case .notFound: isDirectory = false
        }
        guard isDirectory else {
            // The Docker CLI's own words, before it sends anything.
            throw DockerAPIError.badRequest("destination \"\(reference):\(path)\" must be a directory")
        }

        let scratch = try makeScratch(tools)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = scratch.appending(path: "archive.tar")
        let root = scratch.appending(path: "root", directoryHint: .isDirectory)
        guard mkdir(root.path(percentEncoded: false), 0o700) == 0 else {
            throw DockerAPIError.internalError("could not make a directory for the archive")
        }
        try await NIOThreadPool.singleton.runIfActive { try spool(input, to: archive) }
        try refuseCompressed(archive)
        let extractor = DockerTarExtractor(maxBytes: Int.max, maxEntries: Int.max)
        let entries: [DockerExtractedEntry]
        do {
            entries = try await NIOThreadPool.singleton.runIfActive { try extractor.extract(archive, into: root) }
        } catch let rejection as DockerTarRejection {
            throw DockerAPIError.badRequest(rejection.message)
        }
        for entry in entries {
            try await tools.copyIn(
                container, source: root.appending(path: entry.name), destination: destination, mode: entry.mode, copyUIDGID: copyUIDGID, noOverwriteDirNonDir: false,
                requester: requester)
        }
    }

    /// Copies everything `input` holds to a new file at `file`.
    static func spool(_ input: FileHandle, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DockerAPIError.internalError("could not store the archive")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        while let chunk = try input.read(upToCount: DockerLogFile.chunkSize), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
    }

    /// Refuses an archive that starts like gzip, bzip2, xz or zstd: dockerd takes them, this
    /// engine does not, and the Docker CLI never sends one.
    package static func refuseCompressed(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let magic = Array(try handle.read(upToCount: 6) ?? Data())
        let compressed =
            magic.starts(with: [0x1F, 0x8B]) || magic.starts(with: Array("BZh".utf8)) || magic.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
            || magic.starts(with: [0x28, 0xB5, 0x2F, 0xFD])
        if compressed {
            throw DockerAPIError.badRequest("SiliconShip copies an uncompressed tar archive into a container; this one is compressed")
        }
    }
}
