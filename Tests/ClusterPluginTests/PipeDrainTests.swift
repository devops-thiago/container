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

import ContainerizationError
import Foundation
import Synchronization
import Testing

@testable import ContainerCluster

/// The stdout of a command run in a node reaches the host through a pipe whose other end the
/// runtime and the guest hold. These keep that end open the way a stuck command does, and
/// check that the host's end is given up on time all the same.
struct PipeDrainTests {
    /// A pipe whose write end the test holds, standing for the guest.
    private struct Fixture {
        let drain: PipeDrain
        let writer: Int32

        init() throws {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { throw POSIXError(.EMFILE) }
            // A write to a pipe nobody reads reports EPIPE instead of ending the test run.
            _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
            drain = PipeDrain(owning: ends[0])
            writer = ends[1]
        }

        func write(_ text: String) -> Bool {
            let bytes = Array(text.utf8)
            var sent = 0
            while sent < bytes.count {
                let count = bytes[sent...].withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }

        /// Whether the host's end is closed: only then does a write fail with EPIPE.
        var readerIsClosed: Bool {
            var byte: UInt8 = 0
            return Darwin.write(writer, &byte, 1) == -1 && errno == EPIPE
        }

        func closeWriter() { close(writer) }
    }

    /// Counts the kills sent, and lets a test wait for the first.
    private final class Kills: Sendable {
        private let sent: AsyncStream<Void>
        private let send: AsyncStream<Void>.Continuation
        private let total = Mutex(0)
        var count: Int { total.withLock { $0 } }

        init() { (sent, send) = AsyncStream.makeStream() }

        func kill() {
            total.withLock { $0 += 1 }
            send.yield()
        }

        func first() async {
            for await _ in sent { return }
        }
    }

    private func timeout() -> ContainerizationError {
        ContainerizationError(.timeout, message: "process request deadline expired")
    }

    @Test("output larger than a pipe holds is returned whole once the command and its output end", .timeLimit(.minutes(1)))
    func wholeOutput() async throws {
        let fixture = try Fixture()
        let text = String(repeating: "node-a\tTrue\t2026-01-01T00:00:00Z\n", count: 10_000)
        let written = Task.detached {
            let done = fixture.write(text)
            fixture.closeWriter()
            return done
        }
        let kills = Kills()
        let result = try await ClusterHelper.collect(
            from: fixture.drain, deadline: .now.advanced(by: .seconds(30)), wait: { 3 }, kill: { kills.kill() })
        #expect(await written.value)
        #expect(result.code == 3)
        #expect(result.output == text)
        #expect(kills.count == 0)
    }

    @Test("a command that outlives its deadline with stdout open is killed, and the host's end is closed", .timeLimit(.minutes(1)))
    func timeoutWithWriterOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.closeWriter() }
        #expect(fixture.write("partial"))
        let kills = Kills()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        let started = ContinuousClock.now
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.collect(
                from: fixture.drain, deadline: deadline,
                wait: {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw timeout()
                },
                kill: { kills.kill() })
        }
        #expect(failure?.code == .timeout)
        #expect(ContinuousClock.now - started < .seconds(5))
        let output = await fixture.drain.output()
        #expect(!output.complete)
        #expect(fixture.readerIsClosed)
        await kills.first()
        #expect(kills.count == 1)
    }

    @Test("a cancelled capture closes the host's end at once and kills the command", .timeLimit(.minutes(1)))
    func cancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.closeWriter() }
        let kills = Kills()
        let (waiting, wait) = AsyncStream<Void>.makeStream()
        let capture = Task {
            try await ClusterHelper.collect(
                from: fixture.drain, deadline: .now.advanced(by: .seconds(600)),
                wait: {
                    wait.yield()
                    try await Task.sleep(for: .seconds(600))
                    return 0
                },
                kill: { kills.kill() })
        }
        for await _ in waiting { break }
        let started = ContinuousClock.now
        capture.cancel()
        await #expect(throws: CancellationError.self) { try await capture.value }
        let output = await fixture.drain.output()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!output.complete)
        #expect(fixture.readerIsClosed)
        await kills.first()
        #expect(kills.count == 1)
    }

    @Test("a command that exits while something still holds its stdout is a timeout at the deadline, not a partial answer", .timeLimit(.minutes(1)))
    func exitedWithStdoutHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.closeWriter() }
        #expect(fixture.write("node-a\tTrue"))
        let started = ContinuousClock.now
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.collect(
                from: fixture.drain, deadline: .now.advanced(by: .milliseconds(150)), wait: { 0 }, kill: {})
        }
        #expect(failure?.code == .timeout)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(fixture.readerIsClosed)
    }

    @Test("output that ends after the command exits, within the deadline, is returned whole", .timeLimit(.minutes(1)))
    func outputEndsAfterExit() async throws {
        let fixture = try Fixture()
        #expect(fixture.write("first\n"))
        let late = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            let done = fixture.write("second\n")
            fixture.closeWriter()
            return done
        }
        let result = try await ClusterHelper.collect(
            from: fixture.drain, deadline: .now.advanced(by: .seconds(30)), wait: { 0 }, kill: {})
        #expect(await late.value)
        #expect(result.output == "first\nsecond\n")
    }
}
