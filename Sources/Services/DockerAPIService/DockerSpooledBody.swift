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
import NIOPosix

/// A request body written to a file as it arrives, for a route that takes more than is worth
/// holding in memory.
///
/// Writes run on NIO's thread pool, one after another, so the event loop never blocks on the
/// disk. What is waiting to be written is counted: the connection stops reading while that is
/// past `highWater` and reads again once the disk has caught up, so a fast client cannot make
/// the agent hold more than about that much of its body in memory.
///
/// Used only on its connection's event loop.
final class DockerSpooledBody {
    static let highWater = 1 << 20

    let url: URL
    let maxBytes: Int
    private let fd: Int32
    private let eventLoop: any EventLoop
    /// Bytes accepted so far.
    private(set) var received = 0
    /// Bytes accepted and not yet written.
    private(set) var pending = 0
    private var tail: EventLoopFuture<Void>
    private var closed = false

    /// Creates an empty file for the body in `directory`, readable by this user only.
    init(directory: URL, maxBytes: Int, eventLoop: any EventLoop) throws {
        url = directory.appending(path: "docker-body-\(UUID().uuidString)")
        fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.maxBytes = maxBytes
        self.eventLoop = eventLoop
        tail = eventLoop.makeSucceededVoidFuture()
    }

    /// Whether `count` more bytes would pass the bound.
    func wouldExceed(_ count: Int) -> Bool {
        received + count > maxBytes
    }

    /// Queues `chunk` behind what is already queued. `written` runs on the event loop once it
    /// is on disk, or once an earlier write failed and it never will be.
    func append(_ chunk: ByteBuffer, written: @escaping () -> Void) {
        received += chunk.readableBytes
        pending += chunk.readableBytes
        let fd = self.fd
        let count = chunk.readableBytes
        let next = tail.flatMap { [eventLoop] in
            NIOThreadPool.singleton.runIfActive(eventLoop: eventLoop) { try Self.writeAll(fd, chunk) }
        }
        next.assumeIsolated().whenComplete { _ in
            self.pending -= count
            written()
        }
        tail = next
    }

    /// Completes once every queued write is on disk, or fails with the first write that
    /// failed. The file is closed either way; it stays on disk for the route.
    func finish() -> EventLoopFuture<URL> {
        let url = self.url
        return tail.assumeIsolated().always { _ in self.close() }.map { url }.nonisolated()
    }

    /// Closes and deletes the file once what is queued has finished.
    func discard() {
        let url = self.url
        tail.assumeIsolated().whenComplete { _ in
            self.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private static func writeAll(_ fd: Int32, _ buffer: ByteBuffer) throws {
        try buffer.withUnsafeReadableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
