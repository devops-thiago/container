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
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerAPIClient

private actor TerminalSignalProcess: ClientProcess {
    nonisolated let id = "signal-test"
    private let completion = AsyncStream<Int32>.makeStream()
    private(set) var received: [Int32] = []
    let terminatingSignal: Int32

    init(terminatingSignal: Int32) { self.terminatingSignal = terminatingSignal }
    func start() async throws {}
    func resize(_ size: Terminal.Size) async throws {}
    func kill(_ signal: Int32) async throws {
        received.append(signal)
        if signal == SIGUSR1 { throw POSIXError(.EIO) }
        if signal == terminatingSignal { finish(128 + signal) }
    }
    func wait() async throws -> Int32 {
        for await code in completion.stream { return code }
        return -1
    }
    func finish(_ code: Int32) {
        completion.continuation.yield(code)
        completion.continuation.finish()
    }
}

struct ProcessIOSignalTests {
    @Test("external signals reach the guest in raw and canonical modes", arguments: [true, false], [SIGTERM, SIGINT, SIGQUIT, SIGHUP])
    func forwardsSignals(raw: Bool, terminatingSignal: Int32) async throws {
        let process = TerminalSignalProcess(terminatingSignal: terminatingSignal)
        let io = ProcessIO(
            stdin: nil, stdout: nil, stderr: nil, ioTracker: nil,
            stdio: [nil, nil, nil], console: nil, rawConsole: raw)
        let signals = AsyncStream<Int32>.makeStream()
        signals.continuation.yield(SIGWINCH)
        signals.continuation.yield(SIGUSR1)
        signals.continuation.yield(terminatingSignal)
        signals.continuation.finish()
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                await process.finish(-99)
            } catch {}
        }
        defer { watchdog.cancel() }
        let code = try await io.handleProcess(process: process, log: Logger(label: "terminal-signals"), signalStream: signals.stream)
        #expect(code == 128 + terminatingSignal)
        #expect(await process.received == [SIGUSR1, terminatingSignal])
    }
}
