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

import ContainerPlugin
import ContainerizationError
import Foundation
import Synchronization
import SystemPackage

/// One cluster name, held by one create or delete at a time.
///
/// A create records its cluster, then makes its nodes over minutes; a delete lists the nodes,
/// removes them, then removes the record. Run together on one name they undo each other: a
/// delete removes the record of a create that has made no node yet, or misses the worker made
/// after it listed, and a create that fails removes the record a later create replaced its
/// own with. The cluster service cannot tell these apart, since the CLI and the app each run
/// the operation in their own process and the service sees only single calls.
///
/// The hold is a `flock` on a file named for the cluster, so it covers every process that
/// shares the engine's state, and the kernel drops it when the holder exits, however it
/// exits. It is taken without waiting: a create runs for minutes, and the second operation
/// is told why it was refused instead of sitting behind it.
final class ClusterOperationLock: Sendable {
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    /// Where the lock files are kept: beside the plugin's other state, which the app and the
    /// CLI both reach.
    static func defaultDirectory() throws -> FilePath {
        try PluginStateRoot(plugin: ClusterHelper.pluginName).path.appending("operations")
    }

    /// Take the hold on `name`, or throw `.invalidState` if another create or delete has it.
    ///
    /// The file is never removed: a name's lock is the file itself, and unlinking it would
    /// let two operations each hold a different file under the same path.
    static func acquire(name: String, in directory: FilePath) throws -> ClusterOperationLock {
        guard K8sClusters.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "invalid cluster name \(name)")
        }
        do {
            try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        } catch {
            throw ContainerizationError(
                .internalError, message: "cannot create \(directory.string) to serialize operations on cluster \(name)", cause: error)
        }
        let path = directory.appending("\(name).lock").string
        // Close-on-exec: the lock belongs to the open file, and a child that inherited the
        // descriptor would keep the name held after this operation finished.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw ContainerizationError(
                .internalError, message: "cannot open \(path) to serialize operations on cluster \(name)",
                cause: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            guard code == EWOULDBLOCK else {
                throw ContainerizationError(
                    .internalError, message: "cannot lock \(path) to serialize operations on cluster \(name)",
                    cause: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
            }
            throw ContainerizationError(
                .invalidState,
                message: "cluster \(name) is being created or deleted by another operation; try again when it finishes")
        }
        return ClusterOperationLock(descriptor: descriptor)
    }

    /// Give the name up. Closing the descriptor releases the lock; a second call does nothing.
    func release() {
        descriptor.withLock { held in
            if let held { close(held) }
            held = nil
        }
    }
}

extension K8sClusters {
    /// Run `operation` as the only create or delete of cluster `name`.
    ///
    /// Throws `.invalidState`, without running it, while another create or delete of that
    /// name is in flight in this or any other process.
    static func exclusively<T>(
        name: String,
        locks directory: FilePath? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        let lock = try ClusterOperationLock.acquire(name: name, in: try directory ?? ClusterOperationLock.defaultDirectory())
        defer { lock.release() }
        return try await operation()
    }
}
