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
    }

    private static let storage = Mutex<[String: Box]>([:])
    private static let waiters = Mutex<[String: [CheckedContinuation<Void, Never>]]>([:])

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
    public static func attach(label: String, endpoint: xpc_endpoint_t, owner: String? = nil) throws {
        try storage.withLock { table in
            if let existing = table[label]?.owner, existing != owner {
                throw OwnedByAnother(label: label)
            }
            table[label] = Box(endpoint: endpoint, owner: owner)
        }
        let pending = waiters.withLock { $0.removeValue(forKey: label) ?? [] }
        for waiter in pending {
            waiter.resume()
        }
    }

    /// The token `label` was published with, or nil when it is unpublished or unowned.
    public static func owner(label: String) -> String? {
        storage.withLock { $0[label]?.owner }
    }

    public static func remove(label: String) {
        storage.withLock { _ = $0.removeValue(forKey: label) }
    }

    public static func endpoint(label: String) -> xpc_endpoint_t? {
        storage.withLock { $0[label]?.endpoint }
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

    /// Wait for `label` to attach, up to `timeout`. Returns nil on timeout: the
    /// spawn and the attach race, since the caller spawns the instance and then
    /// immediately dials it.
    public static func endpoint(label: String, timeout: Duration) async -> xpc_endpoint_t? {
        if let existing = endpoint(label: label) { return existing }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            let pending = waiters.withLock { $0.removeValue(forKey: label) ?? [] }
            for waiter in pending {
                waiter.resume()
            }
        }
        defer { timeoutTask.cancel() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if endpoint(label: label) != nil {
                cont.resume()
                return
            }
            waiters.withLock { $0[label, default: []].append(cont) }
        }
        return endpoint(label: label)
    }
}
