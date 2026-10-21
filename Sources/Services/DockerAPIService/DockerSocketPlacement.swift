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
        /// A socket a connect failed on for another reason than nobody listening (`errno`):
        /// it may be served, so it is left alone.
        case unreachableSocket(errno: Int32)
        /// Not a socket at all. Never removed: it is not ours.
        case notASocket
    }

    public static func inspect(_ path: String) -> Existing {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .nothing }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .notASocket }
        switch dial(path) {
        case 0:
            return .liveSocket
        // Nobody listens, or it went meanwhile. macOS also refuses a connect to a socket whose
        // backlog is full, so only the lock `DockerSocketClaim` holds tells that one apart.
        case ECONNREFUSED, ENOENT:
            return .staleSocket
        case let code:
            return .unreachableSocket(errno: code)
        }
    }

    /// 0 when a connect to the unix socket at `path` succeeds, else its `errno`.
    static func dial(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return ENAMETOOLONG }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }
}

/// Why an agent may not serve a socket path.
public enum DockerSocketRefusal: Error, Equatable, CustomStringConvertible {
    /// Another agent serves it.
    case served(path: String)
    /// Something other than a socket is there.
    case notASocket(path: String)
    /// A socket is there that could not be told stale (`errno` from the connect).
    case unreachable(path: String, errno: Int32)
    /// The lock beside it could not be taken for another reason than another agent holding it.
    case lock(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .served(let path): "\(path) is already being served"
        case .notASocket(let path): "\(path) exists and is not a socket"
        case .unreachable(let path, let code): "\(path) could not be checked: \(String(cString: strerror(code)))"
        case .lock(let path, let code): "could not lock \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// An agent's hold on the socket path: an exclusive lock on `<socket>.lock` for as long as
/// the agent runs, so that a second agent stops before it touches anything, and the socket and
/// status file this agent made, which are the only ones it removes.
public final class DockerSocketClaim: @unchecked Sendable {
    public let socketPath: String
    private let state = NSLock()
    private var lockDescriptor: Int32
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var status: (url: URL, written: DockerAPIStatus)?

    private init(socketPath: String, lockDescriptor: Int32) {
        self.socketPath = socketPath
        self.lockDescriptor = lockDescriptor
    }

    /// Takes the lock, then clears the way: a stale socket left by an agent that did not get to
    /// clean up is removed; anything else at the path refuses the claim and stays.
    public static func claim(_ socketPath: String) throws(DockerSocketRefusal) -> DockerSocketClaim {
        let lockPath = socketPath + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .lock(path: lockPath, errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? .served(path: socketPath) : .lock(path: lockPath, errno: code)
        }
        let refusal: DockerSocketRefusal?
        switch DockerSocketPlacement.inspect(socketPath) {
        case .nothing:
            refusal = nil
        case .staleSocket:
            unlink(socketPath)
            refusal = nil
        case .liveSocket:
            refusal = .served(path: socketPath)
        case .unreachableSocket(let code):
            refusal = .unreachable(path: socketPath, errno: code)
        case .notASocket:
            refusal = .notASocket(path: socketPath)
        }
        if let refusal {
            close(fd)
            throw refusal
        }
        return DockerSocketClaim(socketPath: socketPath, lockDescriptor: fd)
    }

    /// Notes the socket this agent just bound at the path as its own.
    public func bound() throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        state.withLock { socketIdentity = (info.st_dev, info.st_ino) }
    }

    /// Writes `status` to `url`, as this agent's.
    public func publish(_ status: DockerAPIStatus, to url: URL) throws {
        try status.write(to: url)
        // As read back, so that the comparison at release sees the dates the file holds.
        let written = try DockerAPIStatus.read(from: url)
        state.withLock { self.status = (url, written) }
    }

    /// Removes the socket and status file this agent made, if they are still the ones at their
    /// paths, and lets the lock go. Anything else there is another agent's and stays.
    public func release() {
        state.withLock {
            if let socketIdentity {
                var info = stat()
                if lstat(socketPath, &info) == 0, info.st_dev == socketIdentity.device, info.st_ino == socketIdentity.inode {
                    unlink(socketPath)
                }
                self.socketIdentity = nil
            }
            if let status, (try? DockerAPIStatus.read(from: status.url)) == status.written {
                try? FileManager.default.removeItem(at: status.url)
            }
            status = nil
            if lockDescriptor >= 0 {
                close(lockDescriptor)
                lockDescriptor = -1
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
