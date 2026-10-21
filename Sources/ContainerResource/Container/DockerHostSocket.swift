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
/// socket is the one the Docker API agent serves in the run directory
/// (`PathUtils.dockerSocketPath()`); the path on the host may
/// be another engine's (Docker Desktop's), which a container of this one must never reach.
public enum DockerHostSocket {
    /// The paths that name the host's Docker socket: Docker's, its macOS spelling, and the
    /// one Linux tools use.
    public static let hostPaths: Set<String> = ["/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock"]

    /// Whether a bind of `path` is a bind of the host's Docker socket.
    public static func names(_ path: String) -> Bool {
        hostPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// What a bind of `path` mounts: `enginePath`, the engine's own socket, for the host's
    /// Docker socket, and `path` itself for anything else.
    public static func bindSource(for path: String, enginePath: String) -> String {
        names(path) ? enginePath : path
    }

    /// Whether a socket is at `path` to bind: something has to serve it.
    public static func isServed(at path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
    }

    /// What a bind of the host's Docker socket says when the engine serves none.
    public static let notServedMessage =
        "cannot mount /var/run/docker.sock: SiliconShip is not serving the Docker API; turn on \"Let the Docker CLI use SiliconShip\" in Settings"
}
