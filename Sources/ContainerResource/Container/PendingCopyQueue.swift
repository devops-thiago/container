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

/// Files uploaded into a container that is not running, held on disk until it next starts.
///
/// There is no index. Each upload is a directory of its own that says everything about itself:
/// a record (where its entries go, in what order, with what modes) and the unpacked entries
/// beside it. An upload is written under `staging/` and renamed into
/// `pending/<container>/<order>-<id>` once it is whole, so a queue never holds half an upload;
/// the order is in the name. A directory whose record cannot be read is never deleted: it stays
/// where it is and the start that meets it fails naming it. What is removed is an entry once it
/// is copied in, a container's queue when the container is deleted, and what is left under
/// `staging/`, which nothing ever renamed into a queue.
///
/// The engine's start is the one thing that copies uploads in. It takes a container's queue by
/// renaming `pending/<container>` to `applying/<container>`: whatever was renamed into the queue
/// before that goes with it, and nothing after it does. The rename is the claim; there is no
/// lock. The queue stays taken until the run ends (`release`), so an upload that finds it taken
/// once it is in the queue knows a start has already looked: it renames itself back out, and
/// when that fails the start took it.
public struct PendingCopyQueue: Sendable {
    /// One name at the top of an upload, copied into `Record.destination`.
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let isDirectory: Bool
        /// The mode the archive gave it, for a file.
        public let mode: UInt32

        public init(name: String, isDirectory: Bool, mode: UInt32) {
            self.name = name
            self.isDirectory = isDirectory
            self.mode = mode
        }
    }

    /// What an upload's directory says about it.
    public struct Record: Codable, Sendable, Equatable {
        public var version: Int
        /// The directory in the container the entries go into.
        public let destination: String
        /// What is still to be copied in, in order.
        public var entries: [Entry]
        /// Who sent it, for a folder panel to name.
        public let requester: String?

        public init(destination: String, entries: [Entry], requester: String?) {
            self.version = 1
            self.destination = destination
            self.entries = entries
            self.requester = requester
        }
    }

    /// Why a queue could not be copied in. The message names the upload or the entry.
    public struct Failure: Error, Sendable, CustomStringConvertible {
        /// The upload's directory.
        public let upload: URL
        public let message: String
        public var description: String { message }
    }

    /// Where an agent's held uploads live, from the application root both it and the engine
    /// use: beside the Docker API agent's own state.
    public static let relativePath = "plugin-state/container-docker-api/pending-copies"
    public static let recordName = "record.json"
    public static let rootName = "root"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(appRoot: URL) {
        self.init(directory: appRoot.appending(path: Self.relativePath, directoryHint: .isDirectory))
    }

    var staging: URL { directory.appending(path: "staging", directoryHint: .isDirectory) }
    func pending(_ container: String) -> URL { directory.appending(path: "pending/\(container)", directoryHint: .isDirectory) }
    func applying(_ container: String) -> URL { directory.appending(path: "applying/\(container)", directoryHint: .isDirectory) }

    // MARK: Uploads

    /// A new directory under `staging/` for an upload being written. Its entries are unpacked
    /// into `root` inside it, then it is committed.
    public func stage() throws -> URL {
        try Self.makeDirectory(staging)
        let upload = staging.appending(path: "\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        try Self.makeDirectory(upload, intermediate: false)
        return upload
    }

    /// Where an upload's entries are unpacked.
    public static func root(of upload: URL) -> URL {
        upload.appending(path: rootName, directoryHint: .isDirectory)
    }

    /// Writes `record` into the staged `upload` and renames it to the end of `container`'s
    /// queue. Returns its name there.
    public func commit(_ upload: URL, record: Record, container: String) throws -> String {
        try Self.write(record, into: upload)
        for _ in 0..<16 {
            try Self.makeDirectory(pending(container))
            let name = nextName(container)
            if rename(upload.path(percentEncoded: false), pending(container).appending(path: name).path(percentEncoded: false)) == 0 {
                return name
            }
            // The queue was taken by a start between the two calls, or another upload took
            // the name: try again.
            guard [ENOENT, ENOTEMPTY, EEXIST].contains(errno) else { break }
        }
        throw Failure(upload: upload, message: "could not hold the copy for the container's start: \(String(cString: strerror(errno)))")
    }

    /// Takes the committed upload `name` back out of `container`'s queue, into a staged
    /// directory of its own. nil when it is no longer there to take: a start took it.
    public func takeBack(_ name: String, container: String) throws -> URL? {
        try Self.makeDirectory(staging)
        let upload = staging.appending(path: "\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        if rename(pending(container).appending(path: name).path(percentEncoded: false), upload.path(percentEncoded: false)) == 0 {
            return upload
        }
        guard errno == ENOENT else {
            throw Failure(upload: upload, message: "could not take the copy back: \(String(cString: strerror(errno)))")
        }
        return nil
    }

    /// Whether the upload `name` is being copied in by a start now.
    public func isApplying(_ name: String, container: String) -> Bool {
        FileManager.default.fileExists(atPath: applying(container).appending(path: name).path(percentEncoded: false))
    }

    /// Whether a start has taken `container`'s queue and has not let it go.
    public func isTaken(_ container: String) -> Bool {
        FileManager.default.fileExists(atPath: applying(container).path(percentEncoded: false))
    }

    /// Whether anything waits for `container`'s next start.
    public func holds(_ container: String) -> Bool {
        !Self.uploads(in: pending(container)).isEmpty
    }

    /// Removes what is under `staging/`: uploads that were never committed, left by a service
    /// that stopped while it wrote them, or taken back and not yet removed. Only for a service
    /// starting, while nothing writes there.
    public func sweepStaging() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? [] where name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: staging.appending(path: name))
        }
    }

    /// Drops everything held for `container`, which is gone.
    public func drop(_ container: String) {
        try? FileManager.default.removeItem(at: pending(container))
        try? FileManager.default.removeItem(at: applying(container))
    }

    // MARK: Starts

    /// Takes `container`'s queue for a start. Anything a start before it took and never let go
    /// is put back first, in its place.
    public func claim(_ container: String) throws {
        release(container)
        try Self.makeDirectory(directory.appending(path: "applying", directoryHint: .isDirectory))
        if rename(pending(container).path(percentEncoded: false), applying(container).path(percentEncoded: false)) == 0 { return }
        let reason = errno
        guard reason == ENOENT else {
            throw Failure(upload: pending(container), message: "could not take the copies held for the start: \(String(cString: strerror(reason)))")
        }
        // Nothing is held: the claim still marks the start.
        try Self.makeDirectory(applying(container), intermediate: false)
    }

    /// Copies what the start took for `container` into it with `copyIn`, upload by upload and
    /// entry by entry, in order, removing each once it is in. The first upload whose record
    /// cannot be read, or entry that cannot be copied in, stops it: that and everything after
    /// it go back to the queue for the next start, and the failure names it.
    public func apply(
        _ container: String,
        copyIn: @Sendable (_ source: URL, _ destination: String, _ mode: UInt32, _ requester: String?) async throws -> Void
    ) async throws {
        for (_, upload) in Self.uploads(in: applying(container)) {
            var record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: upload.appending(path: Self.recordName)))
            } catch {
                release(container)
                throw Failure(upload: upload, message: "could not read the copy held in \(upload.path(percentEncoded: false)): \(error)")
            }
            // Whether the record on disk names nothing that is in.
            var recorded = true
            while let entry = record.entries.first {
                let source = Self.root(of: upload).appending(path: entry.name)
                do {
                    try await copyIn(source, record.destination, entry.mode, record.requester)
                } catch {
                    release(container)
                    throw Failure(upload: upload, message: "could not copy \(entry.name) into \(record.destination) before the start: \(Self.reason(error))")
                }
                record.entries.removeFirst()
                // What is in is not copied again. Its source goes only once the record no
                // longer names it: a record that cannot be rewritten leaves the entry, and its
                // source, to be copied again, which overwrites it.
                recorded = (try? Self.write(record, into: upload)) != nil
                if recorded { try? FileManager.default.removeItem(at: source) }
            }
            if recorded { retire(upload) }
        }
    }

    /// Takes a copied-in upload out of its queue whole, then removes it. One that cannot be
    /// taken out stays, with a record naming nothing, and the next start removes it; what is
    /// left of one taken out is under `staging/`, which is swept.
    func retire(_ upload: URL) {
        guard (try? Self.makeDirectory(staging)) != nil else { return }
        let retired = staging.appending(path: "\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        guard rename(upload.path(percentEncoded: false), retired.path(percentEncoded: false)) == 0 else { return }
        try? FileManager.default.removeItem(at: retired)
    }

    /// Lets `container`'s queue go: what the start took and did not copy in goes back to the
    /// queue, in its place, and the queue is no longer taken.
    public func release(_ container: String) {
        let taken = applying(container)
        let left = Self.uploads(in: taken)
        if !left.isEmpty { try? Self.makeDirectory(pending(container)) }
        for (name, upload) in left {
            _ = rename(upload.path(percentEncoded: false), pending(container).appending(path: name).path(percentEncoded: false))
        }
        // Only once it is empty: a directory left behind keeps the queue taken.
        _ = rmdir(taken.path(percentEncoded: false))
    }

    /// Lets every queue go, for an engine starting with no container started.
    public func releaseAll() {
        let root = directory.appending(path: "applying", directoryHint: .isDirectory)
        for container in (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [] {
            release(container)
        }
    }

    // MARK: Internals

    /// The uploads in `queue` that a commit put there, in their order. Anything else is not
    /// touched.
    static func uploads(in queue: URL) -> [(name: String, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: queue.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> (UInt64, String)? in order(of: name).map { ($0, name) } }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { ($0.1, queue.appending(path: $0.1, directoryHint: .isDirectory)) }
    }

    /// The order an upload's name gives it: `<order>-<UUID>`.
    static func order(of name: String) -> UInt64? {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, UUID(uuidString: String(parts[1])) != nil else { return nil }
        return UInt64(parts[0])
    }

    /// A name after everything queued or being copied in for `container`.
    func nextName(_ container: String) -> String {
        let last = (Self.uploads(in: pending(container)) + Self.uploads(in: applying(container))).compactMap { Self.order(of: $0.name) }.max() ?? 0
        return String(format: "%020llu", last + 1) + "-" + UUID().uuidString
    }

    static func write(_ record: Record, into upload: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: upload.appending(path: recordName), options: [.atomic])
    }

    static func makeDirectory(_ url: URL, intermediate: Bool = true) throws {
        if intermediate {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else if mkdir(url.path(percentEncoded: false), 0o700) != 0 {
            throw Failure(upload: url, message: "could not make \(url.path(percentEncoded: false)): \(String(cString: strerror(errno)))")
        }
    }

    static func reason(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
