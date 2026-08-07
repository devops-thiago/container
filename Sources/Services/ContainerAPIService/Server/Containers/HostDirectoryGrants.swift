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

import ContainerAPIClient
import ContainerVersion
import ContainerXPC
import Foundation
import Logging
import XPC

/// Folders this process may open, pooled for the life of the boot rather than per container.
///
/// `HostDirectoryAccess` holds what one container was given. This holds what the *engine* has
/// been given, which is a different question with a different answer, and the reason it exists
/// is the CLI: `container run -v ~/src:/src` reaches this process with no bookmark attached,
/// because the CLI has no grant of its own to attach and no way to obtain one. Nothing in the
/// request says which folder the user meant to allow, only which folder they named.
///
/// So the embedder is the source of every grant, and it reaches here two ways.
///
/// It **publishes** what it already holds — at connect, and whenever the user grants another
/// folder — as freshly minted plain bookmarks. Those are resolved once and kept open for the
/// process lifetime, so any later request naming a folder inside one of them simply works. This
/// is what makes the CLI usable, and it keeps working after the app quits, because what is held
/// here is the extension rather than the bookmark.
///
/// It also **answers**, through an anonymous listener endpoint it announces on the ordinary
/// attach route. When a request names a folder no grant covers, this asks for it, and the app
/// is free to put a panel in front of the user before replying. That is the only route to a
/// folder nobody has granted yet, and it is why an app that is not running turns into an error
/// naming the folder rather than a silent empty mount.
///
/// The app cannot vend a mach service of its own — launchd refuses a name to a process that is
/// not one of its jobs, whatever the app group says (`docs/sandbox-spikes.md`, S7a) — which is
/// why the endpoint is brokered through this process instead of dialled directly.
///
/// Inert unsandboxed: paths open without help, `covers` is true for everything readable, and no
/// embedder ever publishes anything.
public actor HostDirectoryGrants {
    /// One pool per engine. The grants are process-wide by nature — a sandbox extension is held
    /// by the process, not by whoever asked for it — so modelling them per service would be
    /// describing the same operating-system state in two places.
    public static let shared = HostDirectoryGrants()

    private var log: Logger?
    /// Retained because releasing a URL is what ends the access. Never released: the pool is
    /// the boot's worth of grants, and there is no moment before exit at which dropping one is
    /// correct.
    private var granted: [String: URL] = [:]

    /// The label the embedder announces its grant listener under. Not a mach service name — no
    /// process owns it — just the key the attach table files the endpoint under.
    public static var vendorLabel: String { ServiceIdentity.machPrefix + "grants" }

    public func configure(log: Logger) {
        self.log = log
    }

    /// Take grants the embedder pushed, and keep the ones that carry access.
    ///
    /// A bookmark that decodes proves nothing; only opening the folder does (S6d). One that
    /// fails is dropped with a warning rather than refused, because publishing is a bulk
    /// operation and one lapsed entry should not discard the rest.
    @discardableResult
    public func publish(bookmarks: [Data]) -> Int {
        var kept = 0
        for bookmark in bookmarks {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
            else {
                log?.warning("published grant did not resolve")
                continue
            }
            let path = Self.canonical(url.path)
            if granted[path] != nil { continue }
            guard Self.readable(url) else {
                log?.warning("published grant carries no access", metadata: ["path": "\(path)"])
                continue
            }
            granted[path] = url
            kept += 1
            log?.info("host directory granted", metadata: ["path": "\(path)"])
        }
        return kept
    }

    /// Whether `path` can be opened right now — because a pooled grant covers it, or because
    /// this process could open it anyway, which is every path when the engine is unsandboxed.
    ///
    /// A grant on a folder covers everything inside it, so one grant on a home directory
    /// answers for every project in it.
    public func covers(_ path: String) -> Bool {
        let target = Self.canonical(path)
        if granted.keys.contains(where: { target.isPathInside($0) }) { return true }
        return Self.readable(URL(fileURLWithPath: target))
    }

    /// Ask the embedder for a folder nothing has granted yet, and pool what comes back.
    ///
    /// The embedder may show the user a panel before it answers, so this waits longer than an
    /// ordinary call would: the timeout has to be a person's patience, not a machine's.
    ///
    /// - Returns: whether the folder can now be opened.
    public func request(_ path: String) async -> Bool {
        if covers(path) { return true }
        guard let endpoint = InstanceEndpoints.endpoint(label: Self.vendorLabel) else {
            log?.warning(
                "no embedder to ask for a host directory grant", metadata: ["path": "\(path)"])
            return false
        }

        let client = XPCClient(endpoint: endpoint, label: Self.vendorLabel)
        let message = XPCMessage(route: XPCRoute.hostDirectoryGrantRequest.rawValue)
        message.set(key: XPCKeys.hostDirectoryPath.rawValue, value: path)
        do {
            let reply = try await client.send(message, responseTimeout: .seconds(180))
            guard let bookmark = reply.dataNoCopy(key: XPCKeys.hostDirectoryBookmarks.rawValue)
            else {
                log?.info("embedder declined host directory", metadata: ["path": "\(path)"])
                return false
            }
            return publish(bookmarks: [Data(bookmark)]) > 0 && covers(path)
        } catch {
            log?.error(
                "asking the embedder for a host directory failed",
                metadata: ["path": "\(path)", "error": "\(error)"])
            return false
        }
    }

    /// Listing rather than `access(2)`: a bind-mount source is a directory, and what the
    /// sandbox denies is the listing.
    private static func readable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Compared resolved, because the sandbox resolves symlinks before it checks access:
    /// `/tmp/x` and `/private/tmp/x` are one directory however it was spelled.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension String {
    /// Whether this path names `root` itself or something below it — whole components, so
    /// `/opt-data` is not inside `/opt`.
    fileprivate func isPathInside(_ root: String) -> Bool {
        self == root || hasPrefix(root + "/")
    }
}
