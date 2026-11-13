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

/// A command's create and start are requests to the node, and a request can take effect
/// there while its reply is late or given up on. These stand for a node that started the
/// command anyway, and check that the command is killed when the launch fails.
struct CaptureCleanupTests {
    /// The node's side of one command: whether it started, the stdout it holds, the kills
    /// it was sent.
    private final class Guest: Sendable {
        private let state = Mutex<(started: Bool, stdout: Int32, kills: Int, refusals: Int)>((false, -1, 0, 0))
        private let killed: AsyncStream<Void>
        private let kill: AsyncStream<Void>.Continuation
        private let starting: AsyncStream<Void>
        private let start: AsyncStream<Void>.Continuation

        /// `refusing` kills are refused before one is accepted.
        init(refusing refusals: Int = 0) {
            (killed, kill) = AsyncStream.makeStream()
            (starting, start) = AsyncStream.makeStream()
            state.withLock { $0.refusals = refusals }
        }

        var kills: Int { state.withLock { $0.kills } }
        var holdsStdout: Bool { state.withLock { $0.stdout >= 0 } }

        /// The command starts: the node keeps its own copy of the stdout it was given.
        func begin(stdout: FileHandle) {
            state.withLock {
                $0.started = true
                $0.stdout = dup(stdout.fileDescriptor)
            }
            start.yield()
        }

        func begun() async {
            for await _ in starting { return }
        }

        /// A kill arrives. An accepted one ends the command, which lets go of its stdout.
        func receiveKill() throws {
            let accepted = state.withLock { state -> Bool in
                state.kills += 1
                guard state.refusals == 0 else {
                    state.refusals -= 1
                    return false
                }
                if state.stdout >= 0 { close(state.stdout) }
                state.stdout = -1
                return true
            }
            guard accepted else { throw ContainerizationError(.invalidState, message: "process not started") }
            kill.yield()
        }

        func ended() async {
            for await _ in killed { return }
        }
    }

    @Test("a start that took effect and whose reply timed out leaves no command behind", .timeLimit(.minutes(1)))
    func startReplyTimesOut() async throws {
        let guest = Guest()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        let failure = await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.capture(
                deadline: deadline,
                launch: { stdout in
                    guest.begin(stdout: stdout)
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw ContainerizationError(.timeout, message: "process request deadline expired")
                },
                kill: { try guest.receiveKill() })
        }
        #expect(failure?.code == .timeout)
        await guest.ended()
        #expect(guest.kills == 1)
        #expect(!guest.holdsStdout)
    }

    @Test("a capture cancelled while its start is in flight kills the command it started", .timeLimit(.minutes(1)))
    func cancelledDuringStart() async throws {
        let guest = Guest()
        let capture = Task {
            try await ClusterHelper.capture(
                deadline: .now.advanced(by: .seconds(600)),
                launch: { stdout in
                    guest.begin(stdout: stdout)
                    try await Task.sleep(for: .seconds(600))
                    return { 0 }
                },
                kill: { try guest.receiveKill() })
        }
        await guest.begun()
        capture.cancel()
        await #expect(throws: CancellationError.self) { try await capture.value }
        await guest.ended()
        #expect(guest.kills == 1)
        #expect(!guest.holdsStdout)
    }

    @Test("a kill refused because the start had not landed yet is sent again", .timeLimit(.minutes(1)))
    func killBeforeTheStartLanded() async throws {
        let guest = Guest(refusing: 1)
        await #expect(throws: ContainerizationError.self) {
            try await ClusterHelper.capture(
                deadline: .now.advanced(by: .seconds(30)),
                launch: { stdout in
                    guest.begin(stdout: stdout)
                    throw ContainerizationError(.timeout, message: "process request deadline expired")
                },
                kill: { try guest.receiveKill() },
                cleanupPause: .milliseconds(10))
        }
        await guest.ended()
        #expect(guest.kills == 2)
        #expect(!guest.holdsStdout)
    }

    @Test("a command that was never created is given up on after three kills")
    func neverCreated() async {
        let guest = Guest(refusing: .max)
        await ClusterHelper.killUntilSent({ try guest.receiveKill() }, pause: .milliseconds(1))
        #expect(guest.kills == 3)
    }

    @Test("a launch that succeeds hands its output and exit code back, and nothing is killed", .timeLimit(.minutes(1)))
    func launched() async throws {
        let guest = Guest()
        let result = try await ClusterHelper.capture(
            deadline: .now.advanced(by: .seconds(30)),
            launch: { stdout in
                try stdout.write(contentsOf: Data("node-a\tTrue\n".utf8))
                return { 7 }
            },
            kill: { try guest.receiveKill() })
        #expect(result.code == 7)
        #expect(result.output == "node-a\tTrue\n")
        #expect(guest.kills == 0)
    }
}
