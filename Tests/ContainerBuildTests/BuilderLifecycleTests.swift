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

import ContainerizationOS
import Foundation
import Logging
import NIOPosix
import Synchronization
import Testing

@testable import ContainerBuild

/// What the build library leaves running once a build or a connect attempt is over. The
/// app hosts builds in-process for days, so a task or an event loop group left behind per
/// build adds up.
struct BuilderLifecycleTests {
    struct ProbeFailed: Error {}

    static let log = Logger(label: "BuilderLifecycleTests")

    /// The window size a winch command carries.
    static func size(of message: ClientStream) throws -> (rows: UInt16, cols: UInt16) {
        var encoded = message.command.command
        while encoded.count % 4 != 0 { encoded += "=" }
        let json = try #require(Data(base64Encoded: encoded))
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["code"] as? String == "winch")
        let rows = try #require(object["rows"] as? Int)
        let cols = try #require(object["cols"] as? Int)
        return (UInt16(rows), UInt16(cols))
    }

    /// Await `task`, failing the test instead of hanging when it does not end within `seconds`.
    static func awaitEnd(of task: Task<Void, any Error>, within seconds: Int = 10) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.result
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return false
            }
            let ended = try await group.next() ?? false
            group.cancelAll()
            #expect(ended, "the task did not end after it was cancelled")
        }
    }

    /// A connected pair of Unix sockets: an in-process stand-in for the vsock a dial returns.
    static func socketPair() throws -> (FileHandle, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: false), fds[1])
    }

    /// Records each group `connectOnce` shuts down, and shuts it down for real.
    final class GroupShutdowns: Sendable {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }

        func shutDown(_ group: MultiThreadedEventLoopGroup) async {
            count.withLock { $0 += 1 }
            try? await group.shutdownGracefully()
        }
    }

    // MARK: - SIGWINCH relay

    @Test func relaySendsTheSizeOnceThenOnlyChanges() async throws {
        let (signals, signal) = AsyncStream.makeStream(of: Int32.self)
        let (messages, sender) = AsyncStream.makeStream(of: ClientStream.self)
        var sizes = [
            Terminal.Size(width: 80, height: 24),
            Terminal.Size(width: 80, height: 24),
            Terminal.Size(width: 120, height: 40),
        ]
        signal.yield(SIGWINCH)
        signal.yield(SIGWINCH)
        signal.finish()

        try await Builder.relayWindowSize(signals: signals, size: { sizes.removeFirst() }, sender: sender)
        sender.finish()

        var sent: [(rows: UInt16, cols: UInt16)] = []
        for await message in messages {
            sent.append(try Self.size(of: message))
        }
        #expect(sent.count == 2)
        #expect(sent.first?.rows == 24 && sent.first?.cols == 80)
        #expect(sent.last?.rows == 40 && sent.last?.cols == 120)
        #expect(sizes.isEmpty)
    }

    /// The watcher `build` starts for a terminal waits on `SIGWINCH` for as long as it runs;
    /// cancelling it, as `build` does when it ends, must end it.
    @Test func windowSizeWatcherEndsWhenCancelled() async throws {
        let (parent, child) = try Terminal.create(initialSize: .init(width: 100, height: 30))
        defer {
            try? child.close()
            try? parent.close()
        }
        let (messages, sender) = AsyncStream.makeStream(of: ClientStream.self)

        let watcher = Builder.watchWindowSize(of: child, sender: sender)
        var iterator = messages.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let size = try Self.size(of: first)
        #expect(size.rows == 30 && size.cols == 100)

        watcher.cancel()
        try await Self.awaitEnd(of: watcher)
    }

    /// A watcher cancelled before it ever runs still ends.
    @Test func windowSizeWatcherCancelledAtOnceEnds() async throws {
        let (parent, child) = try Terminal.create()
        defer {
            try? child.close()
            try? parent.close()
        }
        let (_, sender) = AsyncStream.makeStream(of: ClientStream.self)

        let watcher = Builder.watchWindowSize(of: child, sender: sender)
        watcher.cancel()
        try await Self.awaitEnd(of: watcher)
    }

    // MARK: - connect

    /// A dial that answered with something the gRPC client cannot use fails in the
    /// builder's set-up; the group made for it must not outlive the attempt.
    @Test func connectAttemptThatCannotSetUpShutsTheGroupDown() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-socket-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let shutdowns = GroupShutdowns()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        await #expect(throws: (any Error).self) {
            _ = try await Builder.connectOnce(socket: handle, group: group, log: Self.log, shutdownGroup: shutdowns.shutDown)
        }
        #expect(shutdowns.calls == 1)
    }

    /// BuildKit not answering yet is the common failure: connect retries every few seconds,
    /// so each failed attempt must stop its client and shut its group down.
    @Test func connectAttemptWhoseProbeFailsShutsTheGroupDown() async throws {
        let (socket, peer) = try Self.socketPair()
        defer { close(peer) }

        let shutdowns = GroupShutdowns()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        await #expect(throws: ProbeFailed.self) {
            _ = try await Builder.connectOnce(
                socket: socket, group: group, log: Self.log,
                probe: { _ in throw ProbeFailed() },
                shutdownGroup: shutdowns.shutDown
            )
        }
        #expect(shutdowns.calls == 1)
    }

    /// A connect that timed out cancels the attempt; a builder it produced anyway has no
    /// owner and must be shut down.
    @Test func connectAttemptCancelledAfterItsProbeShutsTheGroupDown() async throws {
        let (socket, peer) = try Self.socketPair()
        defer { close(peer) }

        let shutdowns = GroupShutdowns()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let attempt = Task {
            _ = try await Builder.connectOnce(
                socket: socket, group: group, log: Self.log,
                probe: { _ in withUnsafeCurrentTask { $0?.cancel() } },
                shutdownGroup: shutdowns.shutDown
            )
        }
        await #expect(throws: CancellationError.self) {
            try await attempt.value
        }
        #expect(shutdowns.calls == 1)
    }

    /// A successful attempt hands the group to the builder, which releases it on shutdown.
    @Test func connectAttemptThatSucceedsLeavesTheGroupToTheBuilder() async throws {
        let (socket, peer) = try Self.socketPair()
        defer { close(peer) }

        let shutdowns = GroupShutdowns()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let builder = try await Builder.connectOnce(
            socket: socket, group: group, log: Self.log,
            probe: { _ in },
            shutdownGroup: shutdowns.shutDown
        )
        #expect(shutdowns.calls == 0)

        await builder.shutdown()
        // Shutting down twice is allowed: `build` does it, and so does a caller that
        // cleans up after a failed build.
        await builder.shutdown()
    }
}
