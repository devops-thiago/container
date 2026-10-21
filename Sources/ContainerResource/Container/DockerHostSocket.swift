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

/// The host's Docker socket, as a bind mount names it.
///
/// Docker Desktop gives a container that binds the host's `/var/run/docker.sock` the socket of
/// the engine it runs on, not whatever the host has at that path. Dev containers, CI runners
/// and Testcontainers' Ryuk bind it so, to reach the engine that runs them. Here that engine's
/// socket is the one its Docker API agent serves in the run directory
/// (`PathUtils.dockerSocketPath(engineAppRoot:)`). On a Mac with Docker Desktop, the host's is
/// Docker Desktop's, which a container of this engine must never reach: a bind of it in any
/// spelling, or through any link, is a bind of this engine's.
public enum DockerHostSocket {
    /// The paths that name the host's Docker socket, compared without case (APFS ignores it):
    /// Docker's, its macOS spelling, and the one Linux tools use.
    public static let hostPaths: Set<String> = ["/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock"]

    /// Where Docker Desktop keeps its socket, under the user's home; `/var/run/docker.sock` is
    /// a link to it.
    public static func desktopSocket(home: String) -> String {
        URL(fileURLWithPath: home).appending(path: ".docker/run/docker.sock").path
    }

    /// The user's home directory: the real one, not a sandbox container's.
    public static var userHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }

    /// Whether a bind of `path` is a bind of the host's Docker socket: one of its spellings, in
    /// any case, or the same socket file as one of `hostSockets` (by device and inode, following
    /// links). Nothing here connects to anything.
    public static func names(_ path: String, home: String = userHome, hostSockets: [String]? = nil) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let spellings = hostPaths.union([desktopSocket(home: home).lowercased(), "/private" + desktopSocket(home: home).lowercased()])
        if spellings.contains(standardized) {
            return true
        }
        guard let file = socketFile(path) else { return false }
        return (hostSockets ?? ["/var/run/docker.sock", desktopSocket(home: home)]).contains { socketFile($0) == file }
    }

    /// The device and inode of the socket at `path`, following links; nil for anything else.
    static func socketFile(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return [UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino)]
    }

    /// What a bind of `path` mounts: `enginePath`, the engine's own socket, for the host's
    /// Docker socket, and `path` itself for anything else.
    public static func bindSource(for path: String, enginePath: String, home: String = userHome, hostSockets: [String]? = nil) -> String {
        names(path, home: home, hostSockets: hostSockets) ? enginePath : path
    }

    /// Whether something answers on the socket at `path`: a connect to it succeeds. A socket
    /// file left by an agent that stopped does not.
    public static func answers(at path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// What a bind of the host's Docker socket says when the engine serves none.
    public static let notServedMessage =
        "cannot mount /var/run/docker.sock: SiliconShip is not serving the Docker API; turn on \"Let the Docker CLI use SiliconShip\" in Settings"
}
