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

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Which request bodies go to a file instead of memory, and how large one may be.
///
/// An image archive is as large as its image, far past what the service holds in memory
/// (`DockerHTTPLimits.maxBodyBytes`). Such a body is written to a file in `directory` as it
/// arrives, with the client held back while the disk catches up, and the route gets the file
/// as `DockerRequest.bodyFile`. The HTTP layer deletes it once the answer has been sent.
public struct DockerBodySpool: Sendable {
    /// Where bodies are written. It must be somewhere the engine can read: the images service
    /// reads a loaded archive itself.
    public var directory: URL
    /// The largest body accepted; past it the request is refused with 413.
    public var maxBytes: Int64
    /// Whether a request's body is spooled, from its method and its path without the version.
    public var accepts: @Sendable (HTTPMethod, [String]) -> Bool

    public init(directory: URL, maxBytes: Int64, accepts: @escaping @Sendable (HTTPMethod, [String]) -> Bool) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.accepts = accepts
    }

    /// The largest image archive `POST /images/load` takes.
    public static let defaultMaxImageArchiveBytes: Int64 = 32 << 30

    /// Spools `POST /images/load`, the archive `docker load` sends.
    public static func imageLoad(directory: URL, maxBytes: Int64 = defaultMaxImageArchiveBytes) -> Self {
        Self(directory: directory, maxBytes: maxBytes) { method, segments in
            method == .POST && segments == ["images", "load"]
        }
    }
}

/// Files the routes and the HTTP layer write and read off the event loop.
enum DockerScratchFile {
    static let chunkSize = 1 << 16

    static var fileIO: NonBlockingFileIO {
        NonBlockingFileIO(threadPool: .singleton)
    }

    /// Writes the file at `url` as the body of a streamed response, a chunk at a time, each
    /// written before the next is read.
    static func stream(_ url: URL, to writer: DockerResponseWriter) async throws {
        let fileIO = Self.fileIO
        try await fileIO.withFileHandle(_deprecatedPath: url.path(percentEncoded: false), mode: .read) { handle in
            while true {
                try Task.checkCancellation()
                let chunk = try await fileIO.read(fileHandle: handle, byteCount: chunkSize, allocator: ByteBufferAllocator())
                guard chunk.readableBytes > 0 else { return }
                try await writer.write(chunk)
            }
        }
    }
}
