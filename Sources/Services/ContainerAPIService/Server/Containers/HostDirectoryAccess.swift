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
/// chose in a file panel, which this process cannot otherwise open: sandbox profiles are
/// per-process, and nothing about the app's access reaches here on its own.
///
/// The grant travels as bookmark data. Apple documents this exact hand-off — an app "can pass
/// that bookmark to another process, like a launch agent or an XPC service", and "the
/// receiving process automatically attempts to extend its sandbox to include the bookmarked
/// resource" — so resolving one here is what makes the directory openable, and the runtime
/// helper spawned for the container inherits that access, which is what lets it hand the
/// directory to `VZVirtioFileSystemDeviceConfiguration`.
///
/// The bookmarks must be plain ones. A *security-scoped* bookmark is the app-scoped kind,
/// which by design only re-extends the sandbox of the app that created it; passing one here
/// resolves to a URL that stays unreadable.
///
/// Unsandboxed this is inert — there is no profile to extend, and paths open directly — so an
/// engine outside a sandbox simply receives no bookmarks.
///
/// Grants are held for the life of the container rather than the bootstrap: a container that
/// is stopped and started again mounts the same directories, and the embedder is not asked
/// for them a second time.
actor HostDirectoryAccess {
    private let log: Logger?
    /// Resolved URLs, retained because releasing them is what ends the access, and because a
    /// URL nothing holds would end it at an arbitrary later moment.
    private var granted: [String: [URL]] = [:]

    init(log: Logger? = nil) {
        self.log = log
    }

    /// Take up the grants for a container.
    ///
    /// A bookmark that will not resolve is logged and skipped rather than thrown: the mount it
    /// belongs to then fails at start with a filesystem error naming the directory, which says
    /// more than a create-time "invalid bookmark" would.
    ///
    /// Stale bookmarks are used anyway. Staleness means the directory moved and the bookmark
    /// was rebuilt from its recorded identity — the resolved URL is still the folder the user
    /// picked, which is the question being asked here.
    func resolve(bookmarks: [Data], for id: String) {
        guard !bookmarks.isEmpty else { return }
        var resolved: [URL] = []
        for bookmark in bookmarks {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                if stale {
                    log?.debug(
                        "host directory bookmark is stale",
                        metadata: ["id": "\(id)", "path": "\(url.path)"])
                }
                resolved.append(url)
            } catch {
                log?.warning(
                    "failed to resolve host directory bookmark",
                    metadata: ["id": "\(id)", "error": "\(error)"])
            }
        }
        guard !resolved.isEmpty else { return }
        granted[id, default: []].append(contentsOf: resolved)
        log?.info(
            "resolved host directory grants",
            metadata: ["id": "\(id)", "count": "\(resolved.count)"])
    }

    /// Give up a container's grants. Idempotent: a container deleted twice, or one that never
    /// had any, is not an error.
    func release(for id: String) {
        guard let urls = granted.removeValue(forKey: id) else { return }
        for url in urls {
            // Matches the implicit start the system performed when the bookmark resolved.
            url.stopAccessingSecurityScopedResource()
        }
        log?.info(
            "released host directory grants",
            metadata: ["id": "\(id)", "count": "\(urls.count)"])
    }

    /// The directories a container currently holds. Exists for tests, which cannot observe a
    /// sandbox profile directly.
    func grantedPaths(for id: String) -> [String] {
        (granted[id] ?? []).map(\.path)
    }
}
