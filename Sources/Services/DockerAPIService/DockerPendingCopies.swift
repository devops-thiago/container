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

/// Archives uploaded into a container that is not running, held until it next starts.
///
/// dockerd writes an upload straight into a stopped container's filesystem. Here a container's
/// filesystem is reachable only while its VM is up, so an upload into a created or exited
/// container is unpacked and checked when it arrives, kept, and copied in when the container
/// next starts: after its bootstrap and before its init process runs, so the process sees the
/// files as if they had always been there. Testcontainers' `withCopyToContainer` relies on
/// that, as does `docker cp` into a created container.
///
/// With a directory, what is held is kept there, each upload in its own directory beside a
/// manifest written after every change, and an agent that restarts finds it again. Without one
/// it lives as long as this service, in the engine's scratch directory.
///
/// Every start that takes a container's queue is stamped with a tick of this store's clock. An
/// upload checked against the tick read before its container's state was is refused once a
/// start has taken the queue since, or while one is under way, and its route copies it in
/// itself: it is never held for a start that has already looked.
public actor DockerPendingCopies {
    /// One upload: what it unpacked to and where it goes.
    struct Upload: Sendable {
        let id: UUID
        /// The upload's own directory, removed once it is copied in or dropped.
        let scratch: URL
        /// Where the archive was unpacked, inside `scratch`.
        let root: URL
        /// What is still to be copied in, in order.
        var entries: [DockerExtractedEntry]
        /// The directory in the container the entries go into.
        let destination: String
        let requester: String?

        init(id: UUID = UUID(), scratch: URL, root: URL, entries: [DockerExtractedEntry], destination: String, requester: String?) {
            self.id = id
            self.scratch = scratch
            self.root = root
            self.entries = entries
            self.destination = destination
            self.requester = requester
        }
    }

    /// The manifest's form on disk.
    struct Manifest: Codable {
        struct Entry: Codable {
            let name: String
            let isDirectory: Bool
            let mode: UInt32
        }

        struct Record: Codable {
            let id: UUID
            /// The upload's directory, in the store's.
            let directory: String
            let engineID: String
            let entries: [Entry]
            let destination: String
            let requester: String?
        }

        var version: Int
        var uploads: [Record]
    }

    public static let manifestName = "manifest.json"
    static let rootName = "root"

    private var uploads: [String: [Upload]] = [:]
    /// Ticks once for every start that takes a queue.
    private var clock: UInt64 = 0
    /// When each container's queue was last taken, by engine ID.
    private var taken: [String: UInt64] = [:]
    /// Containers whose start has taken their queue and has not finished.
    private var starting: Set<String> = []
    /// Containers whose queue is being copied in now.
    private var applying: Set<String> = []
    /// Where what is held is kept; nil keeps it in memory, in the engine's scratch directory.
    public nonisolated let directory: URL?

    /// A store that keeps nothing past this service.
    public init() {
        directory = nil
    }

    /// A store that keeps what it holds in `directory`, and starts from what is there: the
    /// uploads the manifest names whose directory is still there. Any other upload directory
    /// in it is left from one that never finished, and goes. Throws when `directory` cannot
    /// be made or written.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = directory.appending(path: Self.manifestName)
        var loaded: [String: [Upload]] = [:]
        var kept: Set<String> = []
        // A manifest that cannot be read holds nothing, as a missing one does.
        if let data = try? Data(contentsOf: manifest), let document = try? JSONDecoder().decode(Manifest.self, from: data) {
            for record in document.uploads {
                guard UUID(uuidString: record.directory) != nil, !record.entries.isEmpty else { continue }
                let scratch = directory.appending(path: record.directory, directoryHint: .isDirectory)
                let root = scratch.appending(path: Self.rootName, directoryHint: .isDirectory)
                guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else { continue }
                kept.insert(record.directory)
                let entries = record.entries.map { DockerExtractedEntry(name: $0.name, isDirectory: $0.isDirectory, mode: $0.mode) }
                loaded[record.engineID, default: []].append(
                    Upload(id: record.id, scratch: scratch, root: root, entries: entries, destination: record.destination, requester: record.requester))
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        where UUID(uuidString: name) != nil && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        uploads = loaded
        try Self.write(loaded, to: directory)
    }

    /// A directory of its own for an upload that is to be held, in this store's directory; nil
    /// for a store without one, whose uploads stay in the engine's scratch directory.
    nonisolated func makeUploadDirectory() throws -> URL? {
        guard let directory else { return nil }
        let scratch = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        guard mkdir(scratch.path(percentEncoded: false), 0o700) == 0 else {
            throw DockerAPIError.internalError("could not make a directory for the copy: \(String(cString: strerror(errno)))")
        }
        return scratch
    }

    /// The clock now, to check an upload against once it is unpacked.
    func now() -> UInt64 {
        clock
    }

    /// Holds `upload` for `engineID`'s next start, unless a start has taken its queue since the
    /// clock read `observed`, or is taking it now. Returns whether it is held: one that is not
    /// is the caller's to copy in, and its directory the caller's to remove.
    func add(_ upload: Upload, engineID: String, observed: UInt64) throws -> Bool {
        guard taken[engineID, default: 0] <= observed, !starting.contains(engineID) else { return false }
        uploads[engineID, default: []].append(upload)
        do {
            try save()
        } catch {
            uploads[engineID]?.removeAll { $0.id == upload.id }
            if uploads[engineID]?.isEmpty == true { uploads[engineID] = nil }
            throw DockerAPIError.internalError("could not keep the copy for the container's start: \(error)")
        }
        return true
    }

    /// Whether anything waits to be copied into `engineID`.
    public func holds(_ engineID: String) -> Bool {
        !(uploads[engineID] ?? []).isEmpty
    }

    /// Copies what waits for `engineID` into it, in the order it was uploaded, with `copyIn`,
    /// dropping each entry once it is in. The first entry that fails stops it, and the error
    /// names it: that entry and everything after it stay held for the next start.
    ///
    /// - Parameter starting: a start is taking the queue, and holds it until `finishedStart`;
    ///   false for a container already running, started where this service did not see it.
    func apply(
        _ engineID: String, starting: Bool,
        copyIn: (_ source: URL, _ destination: String, _ mode: UInt32, _ requester: String?) async throws -> Void
    ) async throws {
        // Before anything awaits: an upload unpacked from here on is not held for this start.
        clock += 1
        taken[engineID] = clock
        if starting { self.starting.insert(engineID) }
        guard applying.insert(engineID).inserted else { return }
        defer { applying.remove(engineID) }
        while let upload = uploads[engineID]?.first {
            if let entry = upload.entries.first {
                do {
                    try await copyIn(upload.root.appending(path: entry.name), upload.destination, entry.mode, upload.requester)
                } catch {
                    throw DockerAPIError.internalError(
                        "could not copy \(entry.name) into \(upload.destination) before the start: \(DockerContainerProcesses.message(error))")
                }
            }
            // A removal while the copy ran may have dropped it already.
            guard var queue = uploads[engineID], let index = queue.firstIndex(where: { $0.id == upload.id }) else { continue }
            if !queue[index].entries.isEmpty { queue[index].entries.removeFirst() }
            if queue[index].entries.isEmpty {
                try? FileManager.default.removeItem(at: queue[index].scratch)
                queue.remove(at: index)
            }
            uploads[engineID] = queue.isEmpty ? nil : queue
            // What is in is not copied again should this service go before the start ends; a
            // manifest that cannot be written leaves it to be copied again, which overwrites.
            try? save()
        }
    }

    /// The start that took `engineID`'s queue is over, started or not.
    func finishedStart(_ engineID: String) {
        starting.remove(engineID)
    }

    /// Drops what waits for a container that is gone.
    func discard(_ engineID: String) {
        taken[engineID] = nil
        guard let dropped = uploads.removeValue(forKey: engineID) else { return }
        for upload in dropped { try? FileManager.default.removeItem(at: upload.scratch) }
        try? save()
    }

    /// The containers anything waits for.
    func heldContainers() -> [String] {
        uploads.keys.sorted()
    }

    /// A service that is stopping: what lives only in memory goes; what is kept in a directory
    /// stays for the next one.
    func shutdown() {
        guard directory == nil else { return }
        for upload in uploads.values.joined() {
            try? FileManager.default.removeItem(at: upload.scratch)
        }
        uploads = [:]
    }

    private func save() throws {
        guard let directory else { return }
        try Self.write(uploads, to: directory)
    }

    private static func write(_ uploads: [String: [Upload]], to directory: URL) throws {
        let records = uploads.keys.sorted().flatMap { engineID in
            (uploads[engineID] ?? []).map { upload in
                Manifest.Record(
                    id: upload.id, directory: upload.scratch.lastPathComponent, engineID: engineID,
                    entries: upload.entries.map { Manifest.Entry(name: $0.name, isDirectory: $0.isDirectory, mode: $0.mode) },
                    destination: upload.destination, requester: upload.requester)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = directory.appending(path: manifestName)
        try encoder.encode(Manifest(version: 1, uploads: records)).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}
