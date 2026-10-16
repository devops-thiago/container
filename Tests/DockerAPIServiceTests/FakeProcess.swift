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

@testable import DockerAPIService

/// What a fake container process runs: it gets its stdio and returns its exit status.
typealias FakeProgram = @Sendable (FakeIO) async -> Int32

/// A fake container's init process. Like the engine, it holds its own copies of the stdio
/// descriptors a bootstrap passed; the program reads and writes them through NIO, so nothing
/// blocks a cooperative thread. Its exit closes them, which is the EOF the agent reads.
final class FakeProcess: EngineProcess, Sendable {
    private struct State {
        var started = false
        var fds: [Int32?]
        var exitCode: Int32?
        var requested: Int32?
        var program: Task<Void, Never>?
        var waiters: [CheckedContinuation<Int32, Never>] = []
        var sizes: [String] = []
        var notes: [String] = []
    }

    let id: String
    /// Which streams were bound: what the container would see.
    let bound: (stdin: Bool, stdout: Bool, stderr: Bool)
    private let state: Mutex<State>
    private let stopRequested = DockerLatch()
    private let onStart: @Sendable (FakeProcess) throws -> Void
    private let onExit: @Sendable (Int32) -> Void
    /// A copy of stdout something else in the container keeps open past the process's exit.
    private let heldOutput: Int32?

    init(
        id: String, stdio: DockerProcessStdio, holdOutputOpen: Bool = false, onStart: @escaping @Sendable (FakeProcess) throws -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.id = id
        bound = (stdio.stdin != nil, stdio.stdout != nil, stdio.stderr != nil)
        let fds = stdio.handles.map { handle in handle.map { dup($0.fileDescriptor) } }
        state = Mutex(State(fds: fds))
        heldOutput = holdOutputOpen ? stdio.stdout.map { dup($0.fileDescriptor) } : nil
        self.onStart = onStart
        self.onExit = onExit
    }

    deinit {
        state.withLock { $0.fds.compactMap { $0 }.forEach { close($0) } }
        if let heldOutput { close(heldOutput) }
    }

    var exitCode: Int32? { state.withLock { $0.exitCode } }
    var sizes: [String] { state.withLock { $0.sizes } }
    var notes: [String] { state.withLock { $0.notes } }

    func note(_ text: String) {
        state.withLock { $0.notes.append(text) }
    }

    func start() async throws {
        try onStart(self)
    }

    /// Runs `program`, or, without one, waits to be stopped. Called by the engine's start.
    func run(_ program: FakeProgram?) {
        let task = Task {
            let code: Int32
            if let program {
                code = await FakeIO.run(self, program)
            } else {
                await stopRequested.wait()
                code = 0
            }
            publish(code)
        }
        state.withLock {
            $0.started = true
            $0.program = task
        }
    }

    /// Ends the process from outside (stop, kill, delete). Returns false when it is not
    /// running.
    func exit(_ code: Int32) async -> Bool {
        let task = state.withLock { state -> Task<Void, Never>? in
            guard state.started, state.exitCode == nil else { return nil }
            if state.requested == nil { state.requested = code }
            return state.program
        }
        guard let task else { return false }
        stopRequested.open()
        task.cancel()
        await task.value
        return true
    }

    private func publish(_ code: Int32) {
        let (final, waiters, fds) = state.withLock { state -> (Int32, [CheckedContinuation<Int32, Never>], [Int32]) in
            let final = state.requested ?? code
            state.exitCode = final
            defer {
                state.waiters = []
                state.fds = []
            }
            return (final, state.waiters, state.fds.compactMap { $0 })
        }
        // What the program did not take over is closed here, as an exiting process closes it.
        fds.forEach { close($0) }
        onExit(final)
        waiters.forEach { $0.resume(returning: final) }
    }

    func takeFDs() -> [Int32?] {
        state.withLock { state in
            defer { state.fds = [nil, nil, nil] }
            return state.fds
        }
    }

    func wait() async throws -> Int32 {
        await withCheckedContinuation { continuation in
            let code = state.withLock { state -> Int32? in
                if let code = state.exitCode { return code }
                state.waiters.append(continuation)
                return nil
            }
            if let code { continuation.resume(returning: code) }
        }
    }

    func resize(width: UInt16, height: UInt16) async throws {
        state.withLock { $0.sizes.append("\(width)x\(height)") }
    }
}

/// A fake program's stdio.
struct FakeIO: Sendable {
    let process: FakeProcess
    let stdin: NIOAsyncChannelInboundStream<ByteBuffer>?
    let stdout: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    let stderr: NIOAsyncChannelOutboundWriter<ByteBuffer>?

    func write(_ text: String, to stream: StdStream = .stdout) async {
        try? await (stream == .stderr ? stderr : stdout)?.write(ByteBuffer(string: text))
    }

    typealias Pipe = NIOAsyncChannel<ByteBuffer, ByteBuffer>

    static func run(_ process: FakeProcess, _ program: FakeProgram) async -> Int32 {
        let fds = process.takeFDs()
        do {
            var input: Pipe?
            if let fd = fds[0] { input = try await pipe(input: fd) }
            var output: Pipe?
            if let fd = fds[1] { output = try await pipe(output: fd) }
            var errors: Pipe?
            if let fd = fds[2] { errors = try await pipe(output: fd) }
            return try await within(input) { stdin, _ in
                try await within(output) { _, stdout in
                    try await within(errors) { _, stderr in
                        await program(FakeIO(process: process, stdin: stdin, stdout: stdout, stderr: stderr))
                    }
                }
            }
        } catch {
            return 255
        }
    }

    private static func within<R: Sendable>(
        _ pipe: Pipe?, _ body: (NIOAsyncChannelInboundStream<ByteBuffer>?, NIOAsyncChannelOutboundWriter<ByteBuffer>?) async throws -> R
    ) async throws -> R {
        guard let pipe else { return try await body(nil, nil) }
        return try await pipe.executeThenClose { inbound, outbound in
            let result = try await body(inbound, outbound)
            // An exiting process's output is all in the pipe before it is closed.
            await pipe.channel.waitUntilWritten()
            return result
        }
    }

    private static func pipe(input fd: Int32) async throws -> Pipe {
        try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton).takingOwnershipOfDescriptor(input: fd) { channel in
            channel.eventLoop.makeCompletedFuture { try Pipe(wrappingChannelSynchronously: channel) }
        }
    }

    private static func pipe(output fd: Int32) async throws -> Pipe {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton).takingOwnershipOfDescriptor(output: fd) { channel in
            channel.eventLoop.makeCompletedFuture { try Pipe(wrappingChannelSynchronously: channel) }
        }
    }
}

/// Programs the stream tests run.
enum FakePrograms {
    /// Exits at once with `code`.
    static func exit(_ code: Int32) -> FakeProgram {
        { _ in code }
    }

    /// Says `ready;`, answers each chunk of stdin with `got:<chunk>;`, and at the end of stdin
    /// says `eof;` on stdout and `bye;` on stderr, then exits with `code`.
    static func echo(_ code: Int32) -> FakeProgram {
        { io in
            await io.write("ready;")
            if let stdin = io.stdin {
                do {
                    for try await chunk in stdin {
                        let text = String(buffer: chunk)
                        io.process.note("read \(text)")
                        await io.write("got:\(text);")
                    }
                } catch {
                    return 1
                }
            }
            io.process.note("eof")
            await io.write("eof;")
            await io.write("bye;", to: .stderr)
            return code
        }
    }

    /// Writes `output` and exits with `code`, without reading stdin.
    static func say(_ output: String, stderr: String? = nil, code: Int32) -> FakeProgram {
        { io in
            await io.write(output)
            if let stderr { await io.write(stderr, to: .stderr) }
            return code
        }
    }
}
