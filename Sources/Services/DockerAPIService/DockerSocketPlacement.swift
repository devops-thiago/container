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

/// Where the Docker API socket goes, and what to do with whatever is already there.
public enum DockerSocketPlacement {
    public static let socketName = "docker.sock"

    /// The longest unix socket path the Docker CLI can dial. Go's `net` package keeps a path in
    /// `sun_path`, 104 bytes with its terminator, and refuses a longer one before connecting.
    public static let maxPathBytes = 103

    public static func fits(_ path: String) -> Bool {
        path.utf8.count <= maxPathBytes
    }

    /// What is at the socket path before binding.
    public enum Existing: Equatable, Sendable {
        /// Nothing: bind.
        case nothing
        /// A socket nobody answers on, left by an agent that did not get to clean up: remove it.
        case staleSocket
        /// A socket something answers on: another agent holds it, so this one must not.
        case liveSocket
        /// Not a socket at all. Never removed: it is not ours.
        case notASocket
    }

    public static func inspect(_ path: String) -> Existing {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .nothing }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .notASocket }
        return answers(path) ? .liveSocket : .staleSocket
    }

    /// Whether a connect to the unix socket at `path` succeeds.
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

/// What the agent tells the app about its socket, in `docker-api.json` beside it.
///
/// Written whole and atomically, readable only by this user, and removed when the agent stops,
/// so its presence means an agent is (or was, if it crashed) serving at `socketPath`.
public struct DockerAPIStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Serving at `socketPath`.
        case listening
        /// Not serving: the socket path is longer than the Docker CLI can dial.
        case pathTooLong
    }

    public static let fileName = "docker-api.json"

    public var state: State
    public var socketPath: String
    public var pathBytes: Int
    public var maxPathBytes: Int
    public var apiVersion: String
    public var minAPIVersion: String
    public var pid: Int32
    public var startedAt: Date

    public init(state: State, socketPath: String, pid: Int32 = getpid(), startedAt: Date = Date()) {
        self.state = state
        self.socketPath = socketPath
        self.pathBytes = socketPath.utf8.count
        self.maxPathBytes = DockerSocketPlacement.maxPathBytes
        self.apiVersion = DockerAPIVersion.current.description
        self.minAPIVersion = DockerAPIVersion.minimum.description
        self.pid = pid
        self.startedAt = startedAt
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> DockerAPIStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DockerAPIStatus.self, from: Data(contentsOf: url))
    }
}
