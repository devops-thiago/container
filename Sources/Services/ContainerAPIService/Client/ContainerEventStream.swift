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
import ContainerizationError
import Darwin
import Dispatch
import Foundation
import Synchronization

/// A subscription to the API server's container events.
///
/// The stream ends when the server closes it: the server went, or this reader fell behind
/// it. Either way the reader subscribes again with the cursor of the last event it read.
/// If the subscription it then gets says `gap`, events were missed and it has to list again.
public struct ContainerEventSubscription: Sendable {
    /// The server process that numbers these events.
    public let processNonce: String
    /// The last event the server had numbered when this subscription began. Where to resume
    /// from when no event has been read, after a gap or a subscription without a cursor.
    public let cursor: UInt64
    /// What came after the cursor this subscription asked with was not all kept, or that
    /// cursor is another server process's.
    public let gap: Bool
    /// The events: the replayed ones, then each one as it happens.
    public let events: AsyncThrowingStream<ContainerEvent, any Error>

    public init(processNonce: String, cursor: UInt64, gap: Bool, events: AsyncThrowingStream<ContainerEvent, any Error>) {
        self.processNonce = processNonce
        self.cursor = cursor
        self.gap = gap
        self.events = events
    }

    /// Where a reader that has read nothing yet resumes from.
    public var resumeCursor: ContainerEventCursor {
        ContainerEventCursor(processNonce: processNonce, sequence: cursor)
    }
}

/// Why a stream of container events ended other than at its end.
public enum ContainerEventStreamError: Error, CustomStringConvertible {
    /// A line longer than a reader takes.
    case lineTooLong(Int)
    /// The reader did not take the events as fast as they came.
    case fellBehind
    /// A line that is not an event.
    case malformed(String)
    /// Reading the pipe failed.
    case readFailed(Int32)

    public var description: String {
        switch self {
        case .lineTooLong(let limit): "a container event was longer than \(limit) bytes"
        case .fellBehind: "the container events were not read as fast as they came"
        case .malformed(let reason): "a container event could not be read: \(reason)"
        case .readFailed(let error): "reading container events failed: errno \(error)"
        }
    }
}

/// Reads one JSON event per line from a pipe without holding a thread while it waits.
public enum ContainerEventLines {
    public static let maximumLineBytes = 1 << 20
    public static let bufferedEvents = 1024

    /// The events in the pipe `descriptor`, which the stream owns and closes. A line cut
    /// short by the end of the pipe is not an event, and is dropped.
    public static func events(
        from descriptor: Int32, maximumLineBytes: Int = maximumLineBytes, bufferedEvents: Int = bufferedEvents
    ) -> AsyncThrowingStream<ContainerEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ContainerEvent.self, throwing: (any Error).self, bufferingPolicy: .bufferingOldest(bufferedEvents))
        let queue = DispatchQueue(label: "com.apple.container.events.reader")
        let io = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in Darwin.close(descriptor) }
        // Each event as soon as it arrives, rather than once a buffer fills.
        io.setLimit(lowWater: 1)
        let pending = Mutex(Data())
        let ended = Mutex(false)
        let finish: @Sendable ((any Error)?) -> Void = { error in
            let first = ended.withLock { ended in
                defer { ended = true }
                return !ended
            }
            guard first else { return }
            continuation.finish(throwing: error)
            io.close(flags: .stop)
        }
        continuation.onTermination = { _ in finish(nil) }
        io.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
            if let data, !data.isEmpty {
                var lines: [Data] = []
                let overlong = pending.withLock { buffer -> Bool in
                    buffer.append(contentsOf: data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        lines.append(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                    return buffer.count > maximumLineBytes
                }
                for line in lines where !line.isEmpty {
                    guard line.count <= maximumLineBytes else {
                        finish(ContainerEventStreamError.lineTooLong(maximumLineBytes))
                        return
                    }
                    let event: ContainerEvent
                    do {
                        event = try JSONDecoder().decode(ContainerEvent.self, from: line)
                    } catch {
                        finish(ContainerEventStreamError.malformed(String(describing: error)))
                        return
                    }
                    if case .dropped = continuation.yield(event) {
                        finish(ContainerEventStreamError.fellBehind)
                        return
                    }
                }
                if overlong {
                    finish(ContainerEventStreamError.lineTooLong(maximumLineBytes))
                    return
                }
            }
            guard done else { return }
            // ECANCELED is this side closing the stream.
            finish(error == 0 || error == ECANCELED ? nil : ContainerEventStreamError.readFailed(error))
        }
        return stream
    }
}
