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

import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import XPC

/// Endpoint broker for per-container runtime instances under sandboxed
/// embedding.
///
/// A sandboxed embedding cannot give each runtime instance its own launchd
/// mach service name (SMAppService plists are static, and a sandboxed parent
/// can only posix_spawn inherit-sandbox children — spike S2c). Instead, the
/// apiserver spawns each instance directly, and the instance dials the
/// apiserver back over its group mach service and posts the endpoint of its
/// anonymous XPC listener here, keyed by container id. `RuntimeClient` then
/// dials the instance through the brokered endpoint.
/// xpc_endpoint_t is a thread-safe libXPC object; Swift can't see that.
public struct RuntimeEndpoint: @unchecked Sendable {
    public let raw: xpc_endpoint_t
    public init(_ raw: xpc_endpoint_t) { self.raw = raw }
}

public actor RuntimeInstanceRegistry {
    private struct Entry {
        let endpoint: RuntimeEndpoint
        let pid: pid_t
    }

    private var entries: [String: Entry] = [:]
    private var waiters: [String: [CheckedContinuation<RuntimeEndpoint, Never>]] = [:]

    public init() {}

    public func attach(id: String, endpoint: RuntimeEndpoint, pid: pid_t) {
        entries[id] = Entry(endpoint: endpoint, pid: pid)
        for waiter in waiters.removeValue(forKey: id) ?? [] {
            waiter.resume(returning: endpoint)
        }
    }

    public func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    public func pid(id: String) -> pid_t? {
        entries[id]?.pid
    }

    /// Wait for the instance with `id` to attach, up to `timeout`. The spawn
    /// and the attach race: the caller spawns the child and immediately asks
    /// for its endpoint, while the child boots, dials the apiserver, and posts
    /// the endpoint.
    public func endpoint(id: String, timeout: Duration) async throws -> RuntimeEndpoint {
        if let entry = entries[id] {
            return entry.endpoint
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            self.expireWaiters(id: id)
        }
        defer { timeoutTask.cancel() }
        let endpoint: RuntimeEndpoint = await withCheckedContinuation { cont in
            waiters[id, default: []].append(cont)
        }
        // expireWaiters resumes with a dead endpoint; a real attach records
        // the entry first, so its absence distinguishes the timeout.
        guard entries[id] != nil else {
            throw ContainerizationError(
                .internalError,
                message: "timed out waiting for runtime instance \(id) to attach")
        }
        return endpoint
    }

    private func expireWaiters(id: String) {
        guard let pending = waiters.removeValue(forKey: id) else { return }
        let dead = RuntimeEndpoint(xpc_endpoint_create(xpc_connection_create(nil, nil)))
        for waiter in pending {
            waiter.resume(returning: dead)
        }
    }
}

/// XPC harness for the attach route the spawned instances call.
public struct RuntimeAttachHarness: Sendable {
    private let registry: RuntimeInstanceRegistry
    private let log: Logger

    public init(registry: RuntimeInstanceRegistry, log: Logger) {
        self.registry = registry
        self.log = log
    }

    public func attach(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: "id") else {
            throw ContainerizationError(.invalidArgument, message: "runtime attach: missing id")
        }
        guard let rawEndpoint = message.endpoint(key: "endpoint") else {
            throw ContainerizationError(.invalidArgument, message: "runtime attach: missing endpoint")
        }
        let endpoint = RuntimeEndpoint(rawEndpoint)
        let pid = pid_t(message.int64(key: "pid"))
        log.info("runtime instance attached", metadata: ["id": "\(id)", "pid": "\(pid)"])
        await registry.attach(id: id, endpoint: endpoint, pid: pid)
        return message.reply()
    }
}
