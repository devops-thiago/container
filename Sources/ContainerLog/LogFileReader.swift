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

/// Cursor for a descriptor whose inode survives log rollover. The runtime's unique
/// rollover header also detects rewrites that grow past the previous offset between reads.
public struct LogFileReader {
    private let handle: FileHandle
    private var offset: UInt64
    private var head: Data

    public init(handle: FileHandle, startAtEnd: Bool = false) throws {
        self.handle = handle
        self.offset = startAtEnd ? try handle.seekToEnd() : 0
        self.head = try Self.readHead(handle)
    }

    private static func readHead(_ handle: FileHandle) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = pread(handle.fileDescriptor, &bytes, bytes.count, 0)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(bytes.prefix(count))
    }

    /// The file has no name left: its container was deleted.
    public func isDeleted() throws -> Bool {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return info.st_nlink == 0
    }

    /// The file was rewritten from the start since the last read: the engine's rollover of a
    /// full log, or the start of the container's next run.
    public func isRewritten() throws -> Bool {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let headChanged = try !Self.readHead(handle).starts(with: head)
        return UInt64(info.st_size) < offset || headChanged
    }

    public mutating func nextChunk() throws -> Data {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let newHead = try Self.readHead(handle)
        if UInt64(info.st_size) < offset || !newHead.starts(with: head) {
            offset = 0
        }
        head = newHead
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = pread(handle.fileDescriptor, &bytes, bytes.count, off_t(offset))
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += UInt64(count)
        return Data(bytes.prefix(count))
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
    /// read is the last output.
    /// Without `runEnded` it follows until cancelled.
    public static func follow(
        _ handle: FileHandle, statusInterval: Duration = .seconds(1), runEnded: (@Sendable () async throws -> Bool)? = nil,
        onData: @Sendable (Data) -> Void
    ) async throws {
        var reader = try LogFileReader(handle: handle, startAtEnd: true)
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
                if let runEnded, try reader.isRewritten() {
                    // The engine's rollover goes on being read; the next run's start does not.
                    if !ended {
                        lastLook = .now
                        ended = try await runEnded()
                    }
                    if ended { return }
                }
                let data = try reader.nextChunk()
                guard !data.isEmpty else { break }
                onData(data)
            }
            if ended { return }
        }
    }
}
