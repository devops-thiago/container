//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

#if os(macOS)
import ContainerizationError
import Foundation
import Synchronization

public final class XPCClient: Sendable {
    /// The maximum amount of time to wait for a request to a recently
    /// registered XPC service. Once a service has launched, XPC
    /// requests only have milliseconds of overhead, but in some instances,
    /// macOS can take 5 seconds (or considerably longer) to launch a
    /// service after it has been registered.
    public static let xpcRegistrationTimeout: Duration = .seconds(60)

    private nonisolated(unsafe) let connection: xpc_connection_t
    private let q: DispatchQueue?
    private let service: String

    public init(service: String, queue: DispatchQueue? = nil) {
        let connection = xpc_connection_create_mach_service(service, queue, 0)
        self.connection = connection
        self.q = queue
        self.service = service

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    public init(connection: xpc_connection_t, label: String, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.q = queue
        self.service = label

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    deinit {
        self.close()
    }
}

extension XPCClient {
    /// Close the underlying XPC connection.
    public func close() {
        xpc_connection_cancel(connection)
    }

    /// Returns the pid of process to which we have a connection.
    /// Note: `xpc_connection_get_pid` returns 0 if no activity
    /// has taken place on the connection prior to it being called.
    public func remotePid() -> pid_t {
        xpc_connection_get_pid(self.connection)
    }

    /// Install a handler that is called whenever the connection receives an XPC error event.
    ///
    /// This replaces the existing (no-op) event handler. Call this before the first
    /// `send()` to avoid a disconnect-before-handler race.
    ///
    /// ```swift
    /// let client = XPCClient(service: "com.example.myservice")
    /// client.setDisconnectHandler {
    ///     print("service disconnected, cleaning up")
    /// }
    /// let response = try await client.send(request)
    /// ```
    public func setDisconnectHandler(_ handler: @Sendable @escaping () -> Void) {
        xpc_connection_set_event_handler(connection) { object in
            if xpc_get_type(object) == XPC_TYPE_ERROR { handler() }
        }
    }

    /// Create a persistent session backed by this client connection.
    ///
    /// The session installs a disconnect handler at initialisation time, before
    /// any messages are sent, ensuring no server-exit event is missed.
    public func openSession() -> XPCClientSession {
        XPCClientSession(client: self)
    }

    /// Send the provided message to the service.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        // A continuation waiting on an XPC reply cannot be cancelled, so racing it against a
        // timeout in a task group leaves the group waiting for the reply and the timeout never
        // takes effect. Resume the one continuation from whichever of the reply and the timer
        // comes first instead.
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingReply(continuation)
            if let responseTimeout {
                let route = message.string(key: XPCMessage.routeKey) ?? "nil"
                pending.setTimeout(
                    Task {
                        try await Task.sleep(for: responseTimeout)
                        pending.resume(
                            with: .failure(
                                ContainerizationError(
                                    .internalError,
                                    message: "XPC timeout for request to \(self.service)/\(route)"
                                )))
                    })
            }

            xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                pending.resume(with: Result { try self.parseReply(reply) })
            }
        }
    }

    private func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
        switch xpc_get_type(reply) {
        case XPC_TYPE_ERROR:
            var code = ContainerizationError.Code.invalidState
            if reply.connectionError {
                code = .interrupted
            }
            throw ContainerizationError(
                code,
                message: "XPC connection error: \(reply.errorDescription ?? "unknown")"
            )
        case XPC_TYPE_DICTIONARY:
            let message = XPCMessage(object: reply)
            // check errors from our protocol
            try message.error()
            return message
        default:
            fatalError("unhandled xpc object type: \(xpc_get_type(reply))")
        }
    }
}

/// The continuation of a request that is waiting for its reply, which either the reply or the
/// request's timeout can resume. Only the first of them does.
private final class PendingReply: Sendable {
    private struct State {
        var continuation: CheckedContinuation<XPCMessage, any Error>?
        var timeout: Task<Void, any Error>?
    }

    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<XPCMessage, any Error>) {
        self.state = Mutex(State(continuation: continuation))
    }

    func setTimeout(_ task: Task<Void, any Error>) {
        let alreadyResumed = state.withLock { state in
            guard state.continuation != nil else {
                return true
            }
            state.timeout = task
            return false
        }
        if alreadyResumed {
            task.cancel()
        }
    }

    func resume(with result: Result<XPCMessage, any Error>) {
        let (continuation, timeout) = state.withLock { state in
            let taken = (state.continuation, state.timeout)
            state.continuation = nil
            state.timeout = nil
            return taken
        }
        timeout?.cancel()
        continuation?.resume(with: result)
    }
}

#endif
