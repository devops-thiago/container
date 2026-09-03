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
import Synchronization
import XPC

/// Endpoints of spawned plugin instances, keyed by the mach service name they
/// *would* have owned in an unsandboxed install.
///
/// Under sandboxed embedding no spawned process can own a launchd mach name, so
/// each instance posts its anonymous listener endpoint to the apiserver, which
/// records it here. Client types (`RuntimeClient`, `NetworkClient`) consult this
/// table before falling back to a mach-service dial, which keeps their call
/// sites — and upstream's unsandboxed behavior — unchanged.
///
/// Everything lives in the apiserver process: it spawns the instances, receives
/// the attach messages, and hosts the clients that dial them.
public enum InstanceEndpoints {
    /// xpc_endpoint_t is a thread-safe libXPC object; Swift can't see that.
    private struct Box: @unchecked Sendable {
        let endpoint: xpc_endpoint_t
        /// Who published it, as the token they presented; nil for an entry this process
        /// seeded for itself (a resolved endpoint cached locally).
        let owner: String?
        /// The publisher process reported by libXPC for its accepted connection, so a label
        /// whose publisher exited can be published again by a successor with a new token.
        let pid: pid_t?
    }

    private final class WaitRegistration: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Never>?
            var resolved = false
        }

        private let state = Mutex(State())

        /// Install the continuation unless cancellation, timeout, or attach already won.
        func install(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            state.withLock { state in
                guard !state.resolved else { return false }
                state.continuation = continuation
                return true
            }
        }

        func resolve() {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard !state.resolved else { return nil }
                state.resolved = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
    }

    private struct EndpointState {
        var endpoints: [String: Box] = [:]
        var waiters: [String: [UUID: WaitRegistration]] = [:]
    }

    /// Endpoint publication and waiter registration share one lock, closing the attach
    /// check-then-enqueue race. Each waiter has its own identity and terminal resolver.
    private static let state = Mutex(EndpointState())

    /// A label already published under a different owner token.
    public struct OwnedByAnother: Error, CustomStringConvertible {
        public let label: String
        public var description: String { "endpoint label \(label) is owned by another publisher" }
    }

    /// Record `endpoint` under `label` for `owner`.
    ///
    /// A label, once published with a token, can be re-published only with the same token:
    /// re-announces from the same process go through, a second process — same user, same
    /// kit, or something less friendly — cannot take the label over and receive what the
    /// broker sends to it. An entry with no owner is this process's own cache and carries
    /// no such claim.
    /// A publisher that has exited holds nothing: its label may be taken by a new token.
    /// Every publisher process gets a fresh token, so an app relaunched after a force quit — the
    /// engine survives one on purpose — would otherwise find its own label refused until the
    /// engine restarted. The liveness checked is the *recorded* publisher's authoritative XPC
    /// peer PID, not a message field, so a same-user process cannot talk its way past a live app.
    public static func attach(label: String, endpoint: xpc_endpoint_t, owner: String? = nil, pid: pid_t? = nil) throws {
        let pending = try state.withLock { state -> [WaitRegistration] in
            if let existing = state.endpoints[label], let existingOwner = existing.owner, existingOwner != owner {
                guard let previous = existing.pid, !isAlive(previous) else {
                    throw OwnedByAnother(label: label)
                }
            }
            state.endpoints[label] = Box(endpoint: endpoint, owner: owner, pid: pid)
            return state.waiters.removeValue(forKey: label).map { Array($0.values) } ?? []
        }
        for waiter in pending {
            waiter.resolve()
        }
    }

    /// The token `label` was published with, or nil when it is unpublished or unowned.
    public static func owner(label: String) -> String? {
        state.withLock { $0.endpoints[label]?.owner }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    public static func remove(label: String) {
        state.withLock { _ = $0.endpoints.removeValue(forKey: label) }
    }

    public static func endpoint(label: String) -> xpc_endpoint_t? {
        state.withLock { $0.endpoints[label]?.endpoint }
    }

    /// Blocking wait for `label` to attach. The spawner is synchronous and must
    /// not hand back a client before the child has announced itself, or the
    /// client falls back to a mach name no spawned instance owns. Attach
    /// messages are delivered on the XPC listener's own queue, so blocking the
    /// caller here does not block the delivery we are waiting for.
    @discardableResult
    public static func waitForAttach(label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if endpoint(label: label) != nil { return true }
            usleep(20_000)
        }
        return endpoint(label: label) != nil
    }

    /// Wait for `label` to attach, up to `timeout`. Each caller owns one waiter: another
    /// caller's shorter deadline or cancellation cannot resume or remove it.
    public static func endpoint(label: String, timeout: Duration) async -> xpc_endpoint_t? {
        if Task.isCancelled { return nil }
        if let existing = endpoint(label: label) { return existing }

        let id = UUID()
        let registration = WaitRegistration()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await waitForEndpoint(label: label, id: id, registration: registration)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    resolveWaiter(label: label, id: id, registration: registration)
                } catch {
                    // The endpoint waiter won, or the calling task was cancelled.
                }
            }
            _ = await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
        guard !Task.isCancelled else { return nil }
        return endpoint(label: label)
    }

    private static func waitForEndpoint(
        label: String,
        id: UUID,
        registration: WaitRegistration
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyAttached = state.withLock { state -> Bool in
                    if state.endpoints[label] != nil { return true }
                    state.waiters[label, default: [:]][id] = registration
                    return false
                }
                if alreadyAttached {
                    continuation.resume()
                    return
                }
                if !registration.install(continuation) {
                    removeWaiter(label: label, id: id, registration: registration)
                    continuation.resume()
                }
            }
        } onCancel: {
            resolveWaiter(label: label, id: id, registration: registration)
        }
    }

    private static func removeWaiter(
        label: String,
        id: UUID,
        registration: WaitRegistration
    ) {
        state.withLock { state in
            guard state.waiters[label]?[id] === registration else { return }
            state.waiters[label]?[id] = nil
            if state.waiters[label]?.isEmpty == true {
                state.waiters[label] = nil
            }
        }
    }

    private static func resolveWaiter(
        label: String,
        id: UUID,
        registration: WaitRegistration
    ) {
        removeWaiter(label: label, id: id, registration: registration)
        registration.resolve()
    }
}
