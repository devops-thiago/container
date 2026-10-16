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
import Logging
import Synchronization

/// Numbers the container events of one API server process and hands each to every subscriber,
/// one JSON line per event, through a pipe whose read end the subscriber was given.
///
/// Nothing a subscriber does can hold up a change: an event is queued for each subscriber
/// without waiting for any, and written as its pipe takes it. A subscriber that lets its queue
/// grow past its bounds is closed, and reads the end of its stream; so is the oldest one when
/// too many subscribe. The last events are kept, so that one that reconnects with the last
/// event it read gets what it missed, or is told it missed more than is kept.
public final class ContainerEventHub: Sendable {
    public struct Limits: Sendable {
        /// The events kept for a subscriber that reconnects.
        public var replayed: Int
        /// Subscribers at once; one more closes the oldest.
        public var subscribers: Int
        /// Events waiting for one subscriber's pipe.
        public var queuedEvents: Int
        /// Bytes waiting for one subscriber's pipe.
        public var queuedBytes: Int

        public init(replayed: Int = 512, subscribers: Int = 64, queuedEvents: Int = 1024, queuedBytes: Int = 4 << 20) {
            self.replayed = max(0, replayed)
            self.subscribers = max(1, subscribers)
            self.queuedEvents = max(1, queuedEvents)
            self.queuedBytes = max(1, queuedBytes)
        }
    }

    /// What a subscriber is given.
    public struct Subscription: Sendable {
        /// The read end of the subscriber's pipe: one JSON `ContainerEvent` per line, the
        /// replayed ones first. It ends when the subscriber is closed. Not closed when the
        /// handle goes: whoever takes it closes the descriptor, as `XPCMessage.set` does once
        /// it has passed it on.
        public let handle: FileHandle
        public let processNonce: String
        /// The last event this process had numbered when the subscription began. A subscriber
        /// that asked for no replay, or was told of a gap, resumes from here.
        public let cursor: UInt64
        /// The events after the subscriber's cursor are not all kept, or the cursor is another
        /// process's: what it missed cannot be replayed, and it must list again.
        public let gap: Bool
        /// How many events were replayed ahead of the live ones.
        public let replayed: Int
    }

    private struct Subscriber {
        let io: DispatchIO
        var queuedEvents = 0
        var queuedBytes = 0
    }

    private struct State {
        var sequence: UInt64 = 0
        var ring: [ContainerEvent] = []
        var subscribers: [UInt64: Subscriber] = [:]
        var nextID: UInt64 = 0
    }

    public let processNonce: String
    private let limits: Limits
    private let log: Logger
    private let now: @Sendable () -> Date
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.apple.container.events")

    public init(processNonce: String, limits: Limits = Limits(), log: Logger, now: @escaping @Sendable () -> Date = { Date() }) {
        self.processNonce = processNonce
        self.limits = limits
        self.log = log
        self.now = now
    }

    /// The last event numbered so far.
    public var sequence: UInt64 { state.withLock { $0.sequence } }

    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    // MARK: Events

    /// Number an event, keep it for replay, and queue it for every subscriber.
    @discardableResult
    public func emit(
        _ action: ContainerEvent.Action, snapshot: ContainerSnapshot, name: String, exitCode: Int32? = nil, health: HealthStatus? = nil,
        attributes: [String: String] = [:]
    ) -> ContainerEvent {
        let nanos = Int64((now().timeIntervalSince1970 * 1_000_000_000).rounded())
        return state.withLock { state in
            state.sequence += 1
            let event = ContainerEvent(
                sequence: state.sequence, timeNano: nanos, id: snapshot.id, incarnation: snapshot.incarnation, action: action, name: name,
                image: snapshot.configuration.image.reference, labels: snapshot.configuration.labels, exitCode: exitCode, health: health,
                attributes: attributes)
            state.ring.append(event)
            if state.ring.count > limits.replayed {
                state.ring.removeFirst(state.ring.count - limits.replayed)
            }
            guard !state.subscribers.isEmpty, let line = Self.line(event) else { return event }
            for id in state.subscribers.keys.sorted() {
                enqueue(line, for: id, in: &state)
            }
            return event
        }
    }

    // MARK: Subscribers

    /// A new subscriber. With `since`, the events after it come first when they are all still
    /// kept and it is this process's; otherwise the subscription says there is a gap.
    public func subscribe(since: ContainerEventCursor?) throws -> Subscription {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw ContainerizationError(.internalError, message: "could not make a pipe for container events: errno \(errno)")
        }
        let (readFD, writeFD) = (fds[0], fds[1])
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        // A subscriber that went away fails the next write instead of signalling this process.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let io = DispatchIO(type: .stream, fileDescriptor: writeFD, queue: queue) { _ in Darwin.close(writeFD) }

        return state.withLock { state in
            var gap = false
            var replay: [Data] = []
            if let since {
                if since.processNonce != processNonce || since.sequence > state.sequence {
                    gap = true
                } else if since.sequence < state.sequence {
                    let oldest = state.ring.first?.sequence ?? (state.sequence + 1)
                    if since.sequence + 1 < oldest {
                        gap = true
                    } else {
                        replay = state.ring.filter { $0.sequence > since.sequence }.compactMap(Self.line)
                        // More than the subscriber may have queued would close it at once, and it
                        // would ask again for the same: it lists instead.
                        if replay.count > limits.queuedEvents || replay.reduce(0, { $0 + $1.count }) > limits.queuedBytes {
                            replay = []
                            gap = true
                        }
                    }
                }
            }
            if state.subscribers.count >= limits.subscribers, let oldest = state.subscribers.keys.min() {
                log.warning("closing the oldest container events subscriber: too many", metadata: ["limit": "\(limits.subscribers)"])
                close(oldest, in: &state)
            }
            state.nextID += 1
            let id = state.nextID
            state.subscribers[id] = Subscriber(io: io)
            for line in replay {
                enqueue(line, for: id, in: &state)
            }
            return Subscription(
                handle: FileHandle(fileDescriptor: readFD, closeOnDealloc: false), processNonce: processNonce, cursor: state.sequence, gap: gap,
                replayed: replay.count)
        }
    }

    /// Close every subscriber: the server is going.
    public func closeAll() {
        state.withLock { state in
            for id in Array(state.subscribers.keys) { close(id, in: &state) }
        }
    }

    private func enqueue(_ line: Data, for id: UInt64, in state: inout State) {
        guard var subscriber = state.subscribers[id] else { return }
        guard subscriber.queuedEvents < limits.queuedEvents, subscriber.queuedBytes + line.count <= limits.queuedBytes else {
            log.warning(
                "closing a container events subscriber that fell behind",
                metadata: ["queuedEvents": "\(subscriber.queuedEvents)", "queuedBytes": "\(subscriber.queuedBytes)"])
            close(id, in: &state)
            return
        }
        subscriber.queuedEvents += 1
        subscriber.queuedBytes += line.count
        state.subscribers[id] = subscriber
        let size = line.count
        let data = line.withUnsafeBytes { DispatchData(bytes: $0) }
        subscriber.io.write(offset: 0, data: data, queue: queue) { [weak self] done, _, error in
            guard done else { return }
            self?.written(id: id, size: size, error: error)
        }
    }

    private func written(id: UInt64, size: Int, error: Int32) {
        state.withLock { state in
            guard var subscriber = state.subscribers[id] else { return }
            if error != 0 {
                // The subscriber closed its end, or was closed while this waited.
                close(id, in: &state)
                return
            }
            subscriber.queuedEvents -= 1
            subscriber.queuedBytes -= size
            state.subscribers[id] = subscriber
        }
    }

    private func close(_ id: UInt64, in state: inout State) {
        guard let subscriber = state.subscribers.removeValue(forKey: id) else { return }
        // Drops what is still queued: the subscriber reads the end of its stream, and a line
        // cut short before it, which it does not take for an event.
        subscriber.io.close(flags: .stop)
    }

    static func line(_ event: ContainerEvent) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(0x0A)
        return data
    }
}
