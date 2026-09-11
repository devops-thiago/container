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

import ContainerVersion
import ContainerXPC
import ContainerizationError
import Foundation

/// Why the engine lent no folder. The wire form of `HostDirectoryGrants.GrantOutcome`, shared
/// by the server that writes it and the client that reads it.
public enum HostDirectoryLendOutcome: String, Sendable {
    case granted
    case declined
    case noEmbedder
    case timedOut

    /// What the user can do about it, for the command that asked.
    public func message(for path: String, verb: String) -> String {
        switch self {
        case .granted:
            return "\(verb) \(path)"
        case .declined:
            return "cannot \(verb) \(path): permission for that folder was declined. Run this again and choose that folder when asked."
        case .noEmbedder:
            return
                "cannot \(verb) \(path): no permission for that folder, and the app is not open to ask for it. Open SiliconShip and try again, or use a folder you have already granted."
        case .timedOut:
            return "cannot \(verb) \(path): the permission request was not answered within five minutes. Run this again and choose that folder when asked."
        }
    }
}

/// Paths the user typed, made to mean what the user meant.
///
/// Sandboxed, this process starts in its own container, so its working directory is a folder
/// the user has never seen and `.` or `build/Dockerfile` would name the wrong place. The shell
/// records the directory it launched from in `PWD`, and that is what a relative path means.
public enum HostPath {
    public static func absolute(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        let base: String
        if let pwd = environment["PWD"], pwd.hasPrefix("/") {
            base = pwd
        } else {
            base = FileManager.default.currentDirectoryPath
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.path
    }

    /// The folder a lend for `path` should name: the path itself when it is a directory that
    /// exists, its parent otherwise — a file, or a destination nothing has created yet.
    public static func folder(for path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let absolute = self.absolute(path, environment: environment)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), isDirectory.boolValue {
            return absolute
        }
        return URL(fileURLWithPath: absolute).deletingLastPathComponent().path
    }

    /// Copy can create missing destination parents. Ask for the existing ancestor the user
    /// can actually select, rather than a directory that the transfer has yet to create.
    public static func folderForCopy(for path: String) -> String {
        var folder = URL(fileURLWithPath: self.folder(for: path))
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            folder.deleteLastPathComponent()
        }
        return folder.path
    }
}

/// Borrowing a folder from the engine for this process.
///
/// The CLI is sandboxed when it ships inside an app, and a build reads its context here, not
/// in the engine: the Dockerfile, the ignore file and every file the builder asks for go over
/// the build's own connection from this process. The engine holds the folders the user has
/// granted, so this asks it for one — and the engine asks the app, which may show a panel,
/// when nothing covers the path yet. What comes back is a plain bookmark; resolving it here
/// extends this process's sandbox to the folder, and the URL is kept for the rest of the run
/// because releasing it is what ends the access.
public enum ClientHostDirectory {
    private static let held = Held()

    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func keep(_ url: URL) { lock.withLock { urls.append(url) } }
    }

    /// Whether this process needs to borrow anything at all: an unsandboxed CLI opens paths
    /// on its own, and asking would only cost a round trip.
    public static var isSandboxed: Bool { ServiceIdentity.appGroup != nil }

    /// Borrow `path` for this process. Returns the outcome; `.granted` means the folder can be
    /// read from now on.
    public static func lend(path: String) async throws -> HostDirectoryLendOutcome {
        let client = XPCClient(service: ServiceIdentity.apiServerService)
        defer { client.close() }
        let request = XPCMessage(route: .hostDirectoryGrantLend)
        request.set(key: .hostDirectoryPath, value: path)
        // The engine may be waiting on a person at a panel; this has to wait longer than that.
        let reply = try await client.send(request, responseTimeout: XPCClient.grantAwareResponseTimeout)
        return try accept(reply)
    }

    /// Borrow whatever folders `paths` sit in, when this process is sandboxed; nothing
    /// otherwise. `verb` is what the command is about to do with them, for the message when
    /// one cannot be had: "read", "write".
    public static func borrow(_ paths: [String], verb: String) async throws {
        guard isSandboxed else { return }
        var borrowed: Set<String> = []
        for path in paths where path != "-" {
            let folder = HostPath.folder(for: path)
            guard !borrowed.contains(folder) else { continue }
            let outcome = try await lend(path: folder)
            guard case .granted = outcome else {
                throw ContainerizationError(.invalidArgument, message: outcome.message(for: folder, verb: verb))
            }
            borrowed.insert(folder)
        }
    }

    /// Read a lend reply and, when it carries a bookmark, take the access it offers.
    static func accept(_ reply: XPCMessage) throws -> HostDirectoryLendOutcome {
        let outcome = reply.string(key: .hostDirectoryOutcome).flatMap(HostDirectoryLendOutcome.init(rawValue:))
        guard let bookmark = reply.dataNoCopy(key: .hostDirectoryBookmarks) else {
            return outcome ?? .declined
        }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: Data(bookmark), options: [], relativeTo: nil,
                bookmarkDataIsStale: &stale)
        else {
            throw ContainerizationError(.internalError, message: "the engine lent a folder this process could not resolve")
        }
        held.keep(url)
        return .granted
    }
}
