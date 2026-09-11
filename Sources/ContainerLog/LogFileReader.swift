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
    public static func follow(_ handle: FileHandle, onData: @Sendable (Data) -> Void) async throws {
        var reader = try LogFileReader(handle: handle, startAtEnd: true)
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor, eventMask: [.write, .extend, .attrib],
            queue: DispatchQueue(label: "container.log.follow"))
        source.setEventHandler { continuation.yield() }
        source.setCancelHandler {
            try? handle.close()
            continuation.finish()
        }
        source.resume()
        defer { source.cancel() }
        continuation.yield()
        for await _ in events {
            while !Task.isCancelled {
                let data = try reader.nextChunk()
                guard !data.isEmpty else { break }
                onData(data)
            }
        }
    }
}
