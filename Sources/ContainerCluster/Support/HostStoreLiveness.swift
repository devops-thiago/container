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
import SystemPackage

/// Whether a host store process is alive, told from a lock it holds for as long as it runs.
///
/// A connect to the store's socket cannot say: one that is refused is what a store that died
/// leaves behind, and also what a live store gives while its backlog is full. The store
/// therefore takes a `flock` on a file beside its socket before it binds and never lets go
/// of it, so the kernel drops the hold when the process ends, however it ends. Whoever asks
/// tries the same lock without waiting: refused means a store is running.
public enum HostStoreLiveness: Equatable, Sendable {
    /// A store holds the lock.
    case alive
    /// Nothing holds it, or there is no lock file: no store is running.
    case notRunning
    /// The lock could not be tried, so nothing is known.
    case unknown

    /// The lock file of the host store whose socket is `socketPath`.
    public static func lockPath(socketPath: String) -> String { socketPath + ".lock" }

    /// The lock file of this engine's host store.
    public static var lockPath: String { lockPath(socketPath: ClusterHelper.hostStoreSocketPath.string) }

    /// Ask whether a store holds the lock at `lockPath`. Never creates the file, never waits,
    /// and gives up at once the hold it takes when nothing else has one.
    public static func probe(lockPath: String) -> HostStoreLiveness {
        let descriptor = open(lockPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .notRunning : .unknown }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            return errno == EWOULDBLOCK ? .alive : .unknown
        }
        flock(descriptor, LOCK_UN)
        return .notRunning
    }

    /// Take the lock for this process, for the store to call before it binds its socket.
    ///
    /// Returns the descriptor that holds it, which the store keeps open until it exits, or nil
    /// when another process still had the lock after `attempts` tries `pause` apart: a store
    /// that is on its way out, or one asking as `probe` does, lets go within that time.
    public static func hold(
        lockPath: String, attempts: Int = 100, pause: () -> Void = { usleep(100_000) }
    ) throws -> Int32? {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for attempt in 1...max(attempts, 1) {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            guard errno == EWOULDBLOCK || errno == EINTR else {
                let failure = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            if attempt < attempts { pause() }
        }
        close(descriptor)
        return nil
    }
}
