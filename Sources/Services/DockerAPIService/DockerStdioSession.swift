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
import NIOCore
import NIOPosix
import Synchronization

/// Opens once; everyone waiting, before or after, goes through. A waiter whose task is
/// cancelled stops waiting.
final class DockerLatch: Sendable {
    private struct State {
        var open = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns when the latch opens, or at once when the task is cancelled.
    func wait() async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool in
                    if state.open || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Waits for at most `timeout`. Returns whether it opened.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        return isOpen
    }
}

/// The agent's ends of a process's stdio pipes, and the bridging between them and the
/// connections of the attaches its start took.
///
/// Output goes to every attach that asked for it, one chunk at a time and each write awaited,
/// so a slow client holds the pipe back rather than the agent buffering for it; an attach whose
/// client is gone is dropped and the rest go on. With no attach left, the pipe is still read
/// and the output dropped, so the process never blocks on it. Input from the attaches that
/// asked for stdin goes into the stdin pipe; once all of them have ended (the client's
/// half-close), the pipe is closed and the process sees EOF.
final class DockerStdioSession: Sendable {
    typealias Pipe = NIOAsyncChannel<ByteBuffer, ByteBuffer>

    let stdin: Pipe?
    let stdout: Pipe?
    let stderr: Pipe?

    private init(stdin: Pipe?, stdout: Pipe?, stderr: Pipe?) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Takes over the agent's ends of the pipes, which it then closes, whether or not this
    /// succeeds.
    static func connect(stdin: Int32?, stdout: Int32?, stderr: Int32?) async throws -> DockerStdioSession {
        var opened: [Pipe] = []
        var remaining = [stdin, stdout, stderr].compactMap { $0 }
        do {
            var input: Pipe?
            if let stdin {
                remaining.removeAll { $0 == stdin }
                let pipe = try await Self.channel(output: stdin)
                input = pipe
                opened.append(pipe)
            }
            var output: Pipe?
            if let stdout {
                remaining.removeAll { $0 == stdout }
                let pipe = try await Self.channel(input: stdout)
                output = pipe
                opened.append(pipe)
            }
            var errors: Pipe?
            if let stderr {
                remaining.removeAll { $0 == stderr }
                errors = try await Self.channel(input: stderr)
            }
            return DockerStdioSession(stdin: input, stdout: output, stderr: errors)
        } catch {
            for pipe in opened {
                try? await pipe.channel.close()
            }
            for fd in remaining {
                Darwin.close(fd)
            }
            throw error
        }
    }

    private static func channel(input fd: Int32) async throws -> Pipe {
        do {
            return try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton).takingOwnershipOfDescriptor(input: fd) { channel in
                channel.eventLoop.makeCompletedFuture { try Pipe(wrappingChannelSynchronously: channel) }
            }
        } catch {
            // Not taken over, so still ours to close.
            Darwin.close(fd)
            throw error
        }
    }

    private static func channel(output fd: Int32) async throws -> Pipe {
        do {
            return try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton).takingOwnershipOfDescriptor(output: fd) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Pipe(wrappingChannelSynchronously: channel, configuration: .init(isOutboundHalfClosureEnabled: true))
                }
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Closes the pipes of a session that will not run.
    func close() async {
        for pipe in [stdin, stdout, stderr].compactMap({ $0 }) {
            try? await pipe.channel.close()
        }
    }

    /// Bridges until the process exits and its output has been read, then finishes each
    /// attach's output once it has left for its client.
    ///
    /// After the exit, output is read for as long as there is some: a client that reads slowly
    /// still gets all of it. What ends the reading early is a pipe that stays quiet for `drain`
    /// without reaching EOF, because something in the container holds it open past its init
    /// process. Time spent waiting for a slow client does not count towards that.
    func run(_ attaches: [DockerParkedAttach], exited: DockerLatch, drain: Duration) async {
        let sinks = Sinks(attaches)
        let clock = ReaderClock()
        let pipes: [(Pipe, StdStream)] = [stdout.map { ($0, .stdout) }, stderr.map { ($0, .stderr) }].compactMap { $0 }
        for index in pipes.indices {
            clock.waiting(index)
        }
        let readers = Task {
            await withTaskGroup(of: Void.self) { group in
                for (index, (pipe, kind)) in pipes.enumerated() {
                    group.addTask { await Self.forward(pipe, as: kind, to: sinks, clock: clock, index: index) }
                }
            }
        }
        let feeders = attaches.filter(\.options.stdin)
        let stdin = self.stdin
        let writer = Task {
            guard let stdin else { return }
            await Self.feed(stdin, from: feeders)
        }
        await exited.wait()
        let exitedAt = ContinuousClock.now
        let quiet = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if clock.quiet(since: exitedAt, for: drain) {
                    readers.cancel()
                    return
                }
            }
        }
        await readers.value
        quiet.cancel()
        writer.cancel()
        await writer.value
        await withTaskGroup(of: Void.self) { group in
            for attach in attaches {
                group.addTask {
                    await attach.stream.drain()
                    attach.stream.finishWriting()
                }
            }
        }
    }

    private static func forward(_ pipe: Pipe, as kind: StdStream, to sinks: Sinks, clock: ReaderClock, index: Int) async {
        try? await pipe.executeThenClose { inbound, _ in
            var chunks = inbound.makeAsyncIterator()
            while true {
                clock.waiting(index)
                guard let chunk = try await chunks.next() else { break }
                clock.busy(index)
                await sinks.write(chunk, as: kind)
            }
        }
        clock.done(index)
    }

    /// When each output reader began waiting on its pipe, as opposed to on its clients.
    final class ReaderClock: Sendable {
        private let since = Mutex<[Int: ContinuousClock.Instant?]>([:])

        func waiting(_ index: Int) {
            since.withLock { $0[index] = .some(.now) }
        }

        func busy(_ index: Int) {
            since.withLock { $0[index] = .some(nil) }
        }

        func done(_ index: Int) {
            _ = since.withLock { $0.removeValue(forKey: index) }
        }

        /// Whether every reader still going has waited on its pipe, and not on a client, for
        /// `drain` of the time since `start`.
        func quiet(since start: ContinuousClock.Instant, for drain: Duration) -> Bool {
            let now = ContinuousClock.now
            return since.withLock { readers in
                readers.values.allSatisfy { waitingSince in
                    guard let waitingSince else { return false }
                    return max(waitingSince, start).duration(to: now) >= drain
                }
            }
        }
    }

    private static func feed(_ pipe: Pipe, from attaches: [DockerParkedAttach]) async {
        try? await pipe.executeThenClose { _, outbound in
            await withTaskGroup(of: Void.self) { group in
                for attach in attaches {
                    group.addTask {
                        do {
                            for try await chunk in attach.stream.inbound {
                                try await outbound.write(chunk)
                            }
                        } catch {
                            // The client left, or the process closed its stdin: either way
                            // this input is over.
                        }
                    }
                }
            }
            // Every client's input has ended: the process reads EOF once it has read what is
            // still on its way, which closing now would drop. A process that never reads it is
            // left behind when it exits, which cancels this.
            await pipe.channel.waitUntilWritten()
            outbound.finish()
        }
    }

    /// The attaches output goes to, less those whose client is gone.
    final class Sinks: Sendable {
        private let attaches: [DockerParkedAttach]
        private let gone: Mutex<Set<Int>>

        init(_ attaches: [DockerParkedAttach]) {
            self.attaches = attaches
            self.gone = Mutex([])
        }

        func write(_ chunk: ByteBuffer, as kind: StdStream) async {
            for (index, attach) in attaches.enumerated() {
                let wanted = kind == .stderr ? attach.options.stderr : attach.options.stdout
                guard wanted, !gone.withLock({ $0.contains(index) }) else { continue }
                do {
                    try await attach.stream.write(chunk, stream: kind)
                } catch {
                    _ = gone.withLock { $0.insert(index) }
                }
            }
        }
    }
}
