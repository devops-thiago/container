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
import Dispatch
import Foundation

/// The engine's rollover of a full log, told apart from the start of a container's next run.
public enum LogRollover {
    /// How the engine starts a full log again: this, a UUID unique to the rollover, `]` and a
    /// newline. A run's start leaves the log empty for that run's own output instead.
    public static let markerPrefix = "[container log rolled over: "
    static let marker = Data(markerPrefix.utf8)

    /// Whether a follower of one run reads on through a log rewritten from the start, as
    /// `docker logs -f` sends everything its run wrote and nothing of a later run.
    ///
    /// The engine's rollover is the followed run's own, its last segment included, so it is read
    /// whether or not the run has ended since: a run that rolls its log over and exits before the
    /// follower looks still has that last segment read. Any other rewrite is a run's start, read
    /// only while the followed run is still going (`runEnded` is asked, unless `ended` already
    /// says), which it is only for a follower that started before that run did. A next run that
    /// writes a whole log's worth and rolls it over before the follower looks cannot be told from
    /// the followed run's rollover.
    public static func readsRewrite(
        rolledOver: Bool, ended: inout Bool, runEnded: () async throws -> Bool
    ) async throws -> Bool {
        if rolledOver { return true }
        if !ended { ended = try await runEnded() }
        return !ended
    }
}

/// Cursor for a descriptor whose inode survives log rollover. The runtime's unique
/// rollover header also detects rewrites that grow past the previous offset between reads.
public struct LogFileReader: Sendable {
    public static let chunkSize = 64 << 10
    private static let headSize = 128

    public let fd: Int32
    public private(set) var offset: UInt64 = 0
    private var head: Data

    /// From the start of the file. The descriptor stays its owner's to keep open and close.
    public init(fd: Int32) throws {
        self.fd = fd
        self.head = try Self.readHead(fd)
    }

    public init(handle: FileHandle, startAtEnd: Bool = false) throws {
        try self.init(fd: handle.fileDescriptor)
        if startAtEnd { offset = try size() }
    }

    private static func readHead(_ fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: headSize)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(bytes.prefix(count))
    }

    /// Starts from where `tail` lines from the end begin: `nil` for the whole file, 0 for its
    /// end. A last line without its newline counts as a line. At most `maxBytes` before the end
    /// are looked through.
    public mutating func seek(tail lines: Int?, maxBytes: Int = 16 << 20) throws {
        let size = try self.size()
        guard let lines else {
            offset = 0
            return
        }
        guard lines > 0 else {
            offset = size
            return
        }
        // Newlines seen from the end. The one that ends the file ends the last line rather than
        // starting another.
        var seen = 0
        var position = size
        let floor = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while position > floor {
            let count = Int(min(UInt64(Self.chunkSize), position - floor))
            position -= UInt64(count)
            let read = pread(fd, &buffer, count, off_t(position))
            guard read == count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for index in stride(from: count - 1, through: 0, by: -1) where buffer[index] == UInt8(ascii: "\n") {
                let at = position + UInt64(index)
                if at == size - 1 { continue }
                seen += 1
                if seen == lines {
                    offset = at + 1
                    return
                }
            }
        }
        offset = floor
    }

    public func size() throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(info.st_size)
    }

    /// The file has no name left: its container was deleted.
    public func isDeleted() throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_nlink == 0
    }

    /// What has been written since the last read, at most `chunkSize`; empty when there is
    /// nothing new. A file rewritten from the start since the last read is read again from its
    /// top.
    public mutating func next() throws -> Data {
        while true {
            if let data = try read(after: look()) { return data }
        }
    }

    /// As `next()`, except that a file rewritten from the start since the last read is read from
    /// its top only when `readsRewrite`, told whether the engine's rollover rewrote it, says so:
    /// nil when it does not, with the file left unread.
    public mutating func next(readsRewrite: (_ rolledOver: Bool) async throws -> Bool) async throws -> Data? {
        while true {
            let look = try look()
            if look.rewritten, try await !readsRewrite(look.rolledOver) { return nil }
            if let data = try read(after: look) { return data }
        }
    }

    private struct Look {
        let size: UInt64
        let head: Data
        /// Rewritten from the start since the last read: shorter than where the read got to, or
        /// with other first bytes.
        let rewritten: Bool
        let rolledOver: Bool
    }

    private func look() throws -> Look {
        let size = try self.size()
        let newHead = try Self.readHead(fd)
        let rewritten = size < offset || !newHead.starts(with: head)
        return Look(size: size, head: newHead, rewritten: rewritten, rolledOver: rewritten && newHead.starts(with: LogRollover.marker))
    }

    /// Reads on from what `look` found. Nil when the file was rewritten again while it was read:
    /// the bytes may be the new contents, which were not the ones decided on, so they are dropped
    /// and the cursor stays where it was for another look.
    private mutating func read(after look: Look) throws -> Data? {
        let start = look.rewritten ? 0 : offset
        guard look.size > start else {
            offset = start
            head = look.head
            return Data()
        }
        let count = Int(min(UInt64(Self.chunkSize), look.size - start))
        var bytes = [UInt8](repeating: 0, count: count)
        let read = pread(fd, &bytes, count, off_t(start))
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try Self.readHead(fd).starts(with: look.head), try size() >= start + UInt64(read) else { return nil }
        offset = start + UInt64(read)
        head = look.head
        return Data(bytes.prefix(read))
    }
}

public enum LogFileFollow {
    /// Vnode notifications are coalesced signals, never queued log payloads. Cancellation
    /// closes the descriptor only after its dispatch source has finished using it.
    ///
    /// With `runEnded`, the follow ends with the container's run, as `docker logs -f` does:
    /// `runEnded` is asked every `statusInterval`, and the log file is looked at for having
    /// been deleted, with its container, at every change to it, and asked again when the file
    /// is rewritten from the start. Once the run has ended, what is left of it in the file is
    /// read and the follow returns; a file rewritten by the next run's start is not read. The
    /// engine has written all of a process's output by the time it reports the exit, so that
    /// read is the last output. A rewrite from the start is read on or not as
    /// `LogRollover.readsRewrite` says: the engine's rollover is the run's, read even after the
    /// run has ended; the next run's start is not.
    /// Without `runEnded` it follows until cancelled.
    ///
    /// It follows from the end of the file.
    public static func follow(
        _ handle: FileHandle, statusInterval: Duration = .seconds(1), runEnded: (@Sendable () async throws -> Bool)? = nil,
        onData: @Sendable (Data) -> Void
    ) async throws {
        try await follow(
            handle, from: LogFileReader(handle: handle, startAtEnd: true), statusInterval: statusInterval, runEnded: runEnded,
            onData: onData)
    }

    /// As `follow(_:statusInterval:runEnded:onData:)`, from where `start`, a reader of `handle`,
    /// is: what is already there from that point is read first.
    public static func follow(
        _ handle: FileHandle, from start: LogFileReader, statusInterval: Duration = .seconds(1),
        runEnded: (@Sendable () async throws -> Bool)? = nil, onData: @Sendable (Data) -> Void
    ) async throws {
        var reader = start
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor, eventMask: [.write, .extend, .attrib, .delete, .link],
            queue: DispatchQueue(label: "container.log.follow"))
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler {
            try? handle.close()
            continuation.finish()
        }
        source.resume()
        // Taken before the ticker sleeps, so its first wake finds the interval gone by.
        var lastLook = ContinuousClock.now
        // Wakes the loop to ask `runEnded` while the container writes nothing.
        let ticker: Task<Void, Never>? =
            runEnded == nil
            ? nil
            : Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: statusInterval)
                    continuation.yield()
                }
            }
        defer {
            ticker?.cancel()
            source.cancel()
        }
        continuation.yield()
        for await _ in events {
            // Decided before the read below, so that everything written before the end is read.
            var ended = false
            if let runEnded {
                if try reader.isDeleted() {
                    ended = true
                } else if lastLook.duration(to: .now) >= statusInterval {
                    lastLook = .now
                    ended = try await runEnded()
                }
            }
            while !Task.isCancelled {
                let data: Data
                if let runEnded {
                    let next = try await reader.next { rolledOver in
                        try await LogRollover.readsRewrite(rolledOver: rolledOver, ended: &ended) {
                            lastLook = .now
                            return try await runEnded()
                        }
                    }
                    // Rewritten by the next run's start: none of it is the run's.
                    guard let next else { return }
                    data = next
                } else {
                    data = try reader.next()
                }
                guard !data.isEmpty else { break }
                onData(data)
            }
            if ended { return }
        }
    }
}
