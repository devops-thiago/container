//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import ContainerizationError
import Darwin
import Synchronization

/// Represents a long-lived connection to an XPC service on the client side.
///
/// Obtain one via `XPCClient.openSession()`. The disconnect handler is
/// installed at initialisation time, before the first `send()`, so there is
/// no window in which a server crash goes undetected.
public final class XPCClientSession: Sendable {
    private struct State: Sendable {
        var disconnected = false
        var handlers: [@Sendable () async -> Void] = []
    }

    private let client: XPCClient
    private let state = Mutex(State())

    init(client: XPCClient) {
        self.client = client
        client.setDisconnectHandler { [weak self] in
            self?.markDisconnected()
        }
    }

    /// Register a handler to be called when the server disconnects.
    public func onDisconnect(_ handler: @Sendable @escaping () async -> Void) {
        let runImmediately = state.withLock { state in
            if state.disconnected {
                return true
            }
            state.handlers.append(handler)
            return false
        }
        if runImmediately {
            Task { await handler() }
        }
    }

    /// Send a message over the persistent connection.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        try await client.send(
            message,
            responseTimeout: responseTimeout,
            onXPCError: { [weak self] in self?.markDisconnected() },
            admit: { [weak self] submit in
                guard let self else {
                    return false
                }
                return self.state.withLock { state in
                    guard !state.disconnected else {
                        return false
                    }
                    submit()
                    return true
                }
            }
        )
    }

    /// Returns the PID of the process connected to this session.
    /// A request must have completed before this value is expected to be nonzero.
    public func remotePid() -> pid_t {
        client.remotePid()
    }

    /// Permanently close the underlying connection.
    public func close() {
        markDisconnected()
        client.close()
    }

    private func markDisconnected() {
        let handlers = state.withLock { state -> [@Sendable () async -> Void] in
            guard !state.disconnected else {
                return []
            }
            state.disconnected = true
            return state.handlers
        }
        guard !handlers.isEmpty else {
            return
        }
        Task {
            for handler in handlers {
                await handler()
            }
        }
    }
}

#endif
