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

import ContainerResource
import Darwin

/// The process on the other end of a connection: the Docker CLI, a Testcontainers JVM, an IDE.
///
/// Read once, when the connection is accepted (`LOCAL_PEERPID`), so it is the process that
/// connected rather than anything a request says about itself. What it is for is the engine's
/// folder-permission panel, which names who asked for a bind mount or a copy. Display only:
/// nothing here authorizes anything, which is the socket's directory and `LOCAL_PEERCRED`'s job.
public struct DockerPeer: Sendable, Equatable {
    public let pid: pid_t
    /// The process's executable name when it could be read; nil when it could not.
    public let name: String?

    public init(pid: pid_t, name: String?) {
        self.pid = pid
        self.name = name
    }

    /// The peer `pid` with its name read from the system now, or nil for no process.
    public static func resolve(pid: pid_t, name: (pid_t) -> String? = GrantRequester.processName(of:)) -> DockerPeer? {
        guard pid > 0 else { return nil }
        return DockerPeer(pid: pid, name: name(pid))
    }

    /// How the engine's panel names this peer: `docker (pid 4242)`, or `pid 4242` when the name
    /// is not known. Never nil for a real peer, so the engine names the client rather than
    /// falling back to naming this agent, which would be true and of no use to the user.
    public var requester: String {
        GrantRequester.describe(pid: pid, name: { _ in name }) ?? "pid \(pid)"
    }
}
