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

/// Collects what is written to a pipe, until every writer has closed it or it is stopped.
///
/// The pipe is read as bytes arrive, by a dispatch source on a descriptor that never blocks,
/// so nothing sits in a read that only the writer can end: a writer that keeps the pipe open
/// costs no thread and no descriptor once the drain is stopped. Whichever of the two ends it,
/// the descriptor is closed first and the waiters are told after, once each.
final class PipeDrain: @unchecked Sendable {
    /// What was read, and whether the writers closed the pipe. Only a closed pipe is known to
    /// have delivered everything.
    struct Output: Sendable {
        let data: Data
        let complete: Bool
    }

    private struct State {
        var data = Data()
        var complete = false
        var output: Output?
        var waiters: [CheckedContinuation<Output, Never>] = []
    }

    /// The state, in a box the source's handlers can hold: a mutex cannot be copied into them.
    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let shared = Shared()
    private let source: any DispatchSourceRead

    /// Start draining `descriptor`, which the drain now owns and closes.
    init(owning descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "com.apple.container.cluster.pipe-drain"))
        self.source = source
        source.setEventHandler { [shared] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    shared.state.withLock { $0.data.append(contentsOf: buffer[0..<count]) }
                } else if count == 0 {
                    shared.state.withLock { $0.complete = true }
                    source.cancel()
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN {
                    return
                } else {
                    source.cancel()
                    return
                }
            }
        }
        source.setCancelHandler { [shared] in
            close(descriptor)
            let (output, waiters) = shared.state.withLock { state in
                let output = Output(data: state.data, complete: state.complete)
                state.output = output
                defer { state.waiters = [] }
                return (output, state.waiters)
            }
            for waiter in waiters { waiter.resume(returning: output) }
        }
        source.resume()
    }

    /// Stop reading and close the descriptor. What was read so far is the output, marked
    /// incomplete. Does nothing once the pipe has ended.
    func stop() { source.cancel() }

    /// The output, once the pipe has ended or the drain was stopped.
    func output() async -> Output {
        await withCheckedContinuation { continuation in
            let ended = shared.state.withLock { state -> Output? in
                if state.output == nil { state.waiters.append(continuation) }
                return state.output
            }
            if let ended { continuation.resume(returning: ended) }
        }
    }
}

extension ClusterHelper {
    /// The exit code and the output of a command already started with `drain` on its stdout.
    ///
    /// One deadline covers the command and its output. `wait` reports a command that outlives
    /// it; an output that has not ended by then is a timeout too, because only the end of the
    /// pipe says the output is whole, and a part of it must not be read as an answer. However
    /// this returns, the drain is stopped by the deadline at the latest, and by a cancellation
    /// at once. A command that did not finish is sent `kill`, which is not waited for.
    static func collect(
        from drain: PipeDrain,
        deadline: ContinuousClock.Instant,
        wait: @Sendable () async throws -> Int32,
        kill: @Sendable @escaping () async -> Void
    ) async throws -> (code: Int32, output: String) {
        let expiry = Task {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                drain.stop()
            } catch {}
        }
        defer { expiry.cancel() }
        return try await withTaskCancellationHandler {
            let code: Int32
            do {
                code = try await wait()
            } catch {
                drain.stop()
                Task.detached { await kill() }
                throw error
            }
            let output = await drain.output()
            try Task.checkCancellation()
            guard output.complete else {
                // The command exited and something it left behind still holds its stdout.
                throw ContainerizationError(.timeout, message: "the command's output did not end before its deadline")
            }
            return (code, String(decoding: output.data, as: UTF8.self))
        } onCancel: {
            drain.stop()
        }
    }
}
