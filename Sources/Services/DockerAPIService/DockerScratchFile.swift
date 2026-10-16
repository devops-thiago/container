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
import NIOPosix

/// Files the routes read off the event loop.
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
