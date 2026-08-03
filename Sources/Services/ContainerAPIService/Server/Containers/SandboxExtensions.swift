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
import Logging

/// Host directories a sandboxed embedder has granted this process, per container.
///
/// Only meaningful when the engine runs inside an App Sandbox — the arrangement an embedding
/// app needs for Mac App Store distribution. There, a bind mount is a folder the *app's* user
/// chose in a file panel, which this process cannot otherwise open: profiles are per-process,
/// and a security-scoped bookmark is app-keyed and cannot be resolved by a sibling. The app
/// mints a sandbox extension token for each chosen directory and sends it with the create
/// request; consuming one widens this process's profile to include that directory, and the
/// runtime helper spawned for the container inherits the widened profile, which is what lets
/// it hand the directory to `VZVirtioFileSystemDeviceConfiguration`.
///
/// Unsandboxed the calls are inert — there is no profile to widen — so an engine running
/// outside a sandbox simply receives no tokens and opens paths directly.
///
/// Extensions are held for as long as the container exists rather than for the duration of
/// the bootstrap: a container that is stopped and started again mounts the same directories,
/// and re-consuming would need a token the app is no longer being asked for.
actor SandboxExtensions {
    private let log: Logger?
    /// Consumed handles, keyed by container. `release` takes the handle, not the path: two
    /// containers may share a directory and each holds its own extension for it.
    private var handles: [String: [Int64]] = [:]

    init(log: Logger? = nil) {
        self.log = log
    }

    /// Take up the grants for a container. Refused tokens are logged and skipped rather than
    /// thrown: the mount they belong to will fail with a clear filesystem error at start,
    /// which names the directory, where a create-time throw would only say "invalid token".
    func consume(tokens: [String], for id: String) {
        guard !tokens.isEmpty else { return }
        var consumed: [Int64] = []
        for token in tokens {
            let handle = token.withCString { sandbox_extension_consume($0) }
            guard handle > 0 else {
                log?.warning(
                    "failed to consume sandbox extension",
                    metadata: ["id": "\(id)"])
                continue
            }
            consumed.append(handle)
        }
        guard !consumed.isEmpty else { return }
        handles[id, default: []].append(contentsOf: consumed)
        log?.info(
            "consumed sandbox extensions",
            metadata: ["id": "\(id)", "count": "\(consumed.count)"])
    }

    /// Give up a container's grants. Idempotent: a container deleted twice, or one that never
    /// had any, is not an error.
    func release(for id: String) {
        guard let consumed = handles.removeValue(forKey: id) else { return }
        for handle in consumed {
            _ = sandbox_extension_release(handle)
        }
        log?.info(
            "released sandbox extensions",
            metadata: ["id": "\(id)", "count": "\(consumed.count)"])
    }

    /// Whether a container is holding any. Exists for tests, which cannot observe a sandbox
    /// profile directly.
    func holdsExtensions(for id: String) -> Bool {
        !(handles[id]?.isEmpty ?? true)
    }
}

// libsandbox exports these without declaring them in the public `sandbox.h`. Declared here
// rather than resolved with `dlsym` because this process is one Apple already links libsandbox
// into, and a missing symbol should fail the build rather than silently disable bind mounts.
@_silgen_name("sandbox_extension_consume")
private func sandbox_extension_consume(_ token: UnsafePointer<CChar>) -> Int64

@_silgen_name("sandbox_extension_release")
private func sandbox_extension_release(_ handle: Int64) -> Int32
