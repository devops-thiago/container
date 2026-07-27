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
    }

    private static let storage = Mutex<[String: Box]>([:])
    private static let waiters = Mutex<[String: [CheckedContinuation<Void, Never>]]>([:])

    public static func attach(label: String, endpoint: xpc_endpoint_t) {
        storage.withLock { $0[label] = Box(endpoint: endpoint) }
        let pending = waiters.withLock { $0.removeValue(forKey: label) ?? [] }
        for waiter in pending {
            waiter.resume()
        }
    }

    public static func remove(label: String) {
        storage.withLock { _ = $0.removeValue(forKey: label) }
    }

    public static func endpoint(label: String) -> xpc_endpoint_t? {
        storage.withLock { $0[label]?.endpoint }
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
