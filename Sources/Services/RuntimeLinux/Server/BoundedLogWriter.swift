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

import Containerization
import Foundation
import Synchronization

/// One bounded stdio segment, shared by stdout and stderr. Rollover rewrites the same
/// inode so readers holding an XPC-transferred descriptor can keep following it.
final class BoundedLogWriter: Sendable {
    static let defaultMaximumBytes = 10 * 1024 * 1024
    static let markerPrefix = "[container log rolled over: "

    struct Operations: Sendable {
        var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
        var truncate: @Sendable (FileHandle) throws -> Void = { try $0.truncate(atOffset: 0) }
    }

    private struct State {
        var bytes: Int
        var failure: (any Error)?
        var closed = false
    }

    private let state: Mutex<State>
    private let handle: FileHandle
    private let maximumBytes: Int
    private let operations: Operations
    private let onFailure: @Sendable (any Error) -> Void

    init(
        handle: FileHandle,
        maximumBytes: Int = defaultMaximumBytes,
        operations: Operations = .init(),
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) throws {
        // The fixed-length UUID marker must leave space for at least one byte.
        guard maximumBytes >= 128 else { throw POSIXError(.EINVAL) }
        self.handle = handle
        self.maximumBytes = maximumBytes
        self.operations = operations
        self.onFailure = onFailure
        let size = try handle.seekToEnd()
        self.state = Mutex(State(bytes: Int(size)))
    }

    /// A failed sink stays failed until restart: never retry disk I/O on each guest
    /// callback. Report the transition once, while MultiWriter keeps attached output live.
    func write(_ data: Data) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            guard !state.closed else { throw POSIXError(.EBADF) }
            guard !data.isEmpty else { return }
            do {
                if data.count > maximumBytes - state.bytes {
                    let marker = Data("\(Self.markerPrefix)\(UUID().uuidString)]\n".utf8)
                    try operations.truncate(handle)
                    try handle.seek(toOffset: 0)
                    state.bytes = 0
                    try operations.write(handle, marker)
                    state.bytes = marker.count
                    // A single guest write may exceed the entire budget. Keep its tail
                    // without looping through discarded segments or allocating a huge copy.
                    let tail = data.suffix(maximumBytes - marker.count)
                    try operations.write(handle, Data(tail))
                    state.bytes += tail.count
                } else {
                    try operations.write(handle, data)
                    state.bytes += data.count
                }
            } catch {
                state.failure = error
                onFailure(error)
                throw error
            }
        }
    }

    func close() throws {
        try state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            try handle.close()
        }
    }
}

/// Each stream owns its attached handle; both share the serialized disk sink. Attached
/// bytes are never truncated. A failed attachment must not suppress detached logging.
struct MultiWriter: Writer {
    let handles: [FileHandle]
    let log: BoundedLogWriter

    // RuntimeService calls both closes only at process teardown, after container.wait()
    // waits for both output streams. Individual stdout/stderr EOF never closes this sink.
    func close() throws {
        defer { try? log.close() }
        for handle in handles { try handle.close() }
    }

    func write(_ data: Data) throws {
        var attachmentFailure: (any Error)?
        for handle in handles {
            do { try handle.write(contentsOf: data) } catch { attachmentFailure = error }
        }
        // BoundedLogWriter reports a permanent logging failure once. Do not let the
        // containerization callback report it for every subsequent guest chunk, which
        // would simply move a noisy container's disk flood into unified logging.
        do { try log.write(data) } catch {}
        if let attachmentFailure { throw attachmentFailure }
    }
}
