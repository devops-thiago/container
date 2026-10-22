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

/// A container's init process once it is bootstrapped, as the stream routes drive it. The agent
/// answers it with the engine's process client; tests answer it with a fake.
public protocol EngineProcess: Sendable {
    /// Starts the process. Its stdio was bound at bootstrap.
    func start() async throws
    /// Waits for the process to exit and returns its status.
    func wait() async throws -> Int32
    /// Sets the size of the process's terminal.
    func resize(width: UInt16, height: UInt16) async throws
}

/// The container's ends of the pipes a bootstrap binds as its init process's stdio. A missing
/// stream is not connected.
///
/// The engine closes each descriptor it is given once it has sent it, as `XPCMessage.set` does,
/// so these are copies (`StdioPipe.containerHandleForEngine()`): the pipe closes its own end
/// once the engine holds its copies, and a pipe's far end sees EOF when the process exits.
public struct DockerProcessStdio: Sendable {
    public let stdin: FileHandle?
    public let stdout: FileHandle?
    public let stderr: FileHandle?

    public init(stdin: FileHandle? = nil, stdout: FileHandle? = nil, stderr: FileHandle? = nil) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    /// In the order bootstrap takes them: stdin, stdout, stderr.
    public var handles: [FileHandle?] { [stdin, stdout, stderr] }

    /// No stdio at all: what a detached start binds.
    public static let detached = Self()
}

/// One OS pipe. The agent keeps one end and the container gets the other; whichever end is
/// still held when the pipe goes is closed then.
final class StdioPipe {
    /// The end the agent keeps: the write end of stdin, the read end of stdout and stderr.
    private(set) var host: Int32?
    /// The end the container gets.
    private(set) var container: Int32?

    enum Direction {
        /// The agent writes, the container reads.
        case intoContainer
        /// The container writes, the agent reads.
        case outOfContainer
    }

    init(_ direction: Direction) throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        switch direction {
        case .intoContainer:
            host = fds[1]
            container = fds[0]
            // A write after the container closed its end fails with EPIPE rather than killing
            // the agent with SIGPIPE.
            _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        case .outOfContainer:
            host = fds[0]
            container = fds[1]
        }
    }

    /// A copy of the container's end for the engine to send. The engine's request closes the
    /// descriptor it is given (`XPCMessage.set`), and this pipe still closes its own in
    /// `closeContainerEnd()`. Handing over the pipe's own descriptor closed it twice: the second
    /// close hit whatever had reused the number by then, such as another exec's stdin, and the
    /// agent trapped on that descriptor. A copy the engine never sends stays open.
    func containerHandleForEngine() throws -> FileHandle? {
        guard let container else { return nil }
        let copy = fcntl(container, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: false)
    }

    /// Gives up the host end to a new owner, which closes it.
    func takeHost() -> Int32? {
        defer { host = nil }
        return host
    }

    /// Closes the container's end, once the engine holds its own copy: until it does, the
    /// agent's end never sees EOF.
    func closeContainerEnd() {
        if let container { close(container) }
        container = nil
    }

    deinit {
        if let host { close(host) }
        if let container { close(container) }
    }
}
