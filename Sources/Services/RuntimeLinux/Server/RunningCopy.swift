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
import Containerization
import ContainerizationError
import Foundation
import Synchronization

/// Copies into and out of a started container through the VM's agent.
///
/// containerization's `LinuxContainer.copyIn` and `copyOut` hold the container's lock for the
/// whole transfer, and its `exec`, `kill`, `statistics` and `dialVsock` take the same lock, so
/// while a copy of a few GB ran no exec or signal reached the container: a 2 GB copy kept a
/// new exec waiting for over 20 s. The copies here do what those do, with the same results,
/// but the caller looks the VM up with `withVirtualMachineInstance`, which holds the lock only
/// for the lookup. A container that stops during a copy ends it: the stop cancels it through
/// `ActiveCopies`, and the VM going away fails whatever is left.
enum RunningCopy {
    /// Copy `source` on the host to `destination` in the container, resolved as
    /// containerization's `copyIn` resolves it: into an existing directory under the source's
    /// name, else at the path itself, and a missing directory (a trailing `/`) is refused for
    /// a file.
    static func copyIn(
        from source: URL, to destination: URL, mode: UInt32, createParents: Bool, rootfs: String, owner: CopyOwner? = nil,
        agent: some GuestCopyAgent
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ContainerizationError(.notFound, message: "copyIn: source not found '\(source.path)'")
        }
        let path = try await destinationPath(
            from: source, to: destination, sourceIsDirectory: isDirectory.boolValue, rootfs: rootfs, agent: agent)
        try await agent.copy(
            from: source, isDirectory: isDirectory.boolValue, root: rootfs, path: path, mode: mode, createParents: createParents,
            owner: owner)
    }

    /// Copy `source` in the container to `destination` on the host: a directory as its
    /// contents at `destination`, a file as `destination`.
    static func copyOut(from source: String, to destination: URL, createParents: Bool, rootfs: String, agent: some GuestCopyAgent) async throws {
        if createParents {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try await agent.copyOut(root: rootfs, path: source, to: destination)
    }

    /// Where a copy in lands, as containerization's `copyIn` decides it. The destination is
    /// looked at in the guest only to copy into an existing directory; the agent resolves the
    /// path it is given confined to the root filesystem when it writes.
    static func destinationPath(
        from source: URL, to destination: URL, sourceIsDirectory: Bool, rootfs: String, agent: some GuestCopyAgent
    ) async throws -> String {
        guard let existing = try await agent.identity(root: rootfs, path: destination.path) else {
            if destination.hasDirectoryPath && !sourceIsDirectory {
                throw ContainerizationError(.invalidArgument, message: "destination directory does not exist: \(destination.path)")
            }
            return destination.path
        }
        guard existing.isDirectory else {
            if sourceIsDirectory {
                throw ContainerizationError(.invalidArgument, message: "cannot copy directory over existing file: \(destination.path)")
            }
            return destination.path
        }
        return destination.appendingPathComponent(source.lastPathComponent).path
    }

    /// Run `body` with an agent of `container`'s VM, holding the container's lock only to look
    /// the VM up.
    static func withAgent<T: Sendable>(
        of container: LinuxContainer, _ body: @Sendable (Vminitd, any VirtualMachineInstance) async throws -> T
    ) async throws -> T {
        try await container.withVirtualMachineInstance { vm in
            let agent = try await vm.dialAgent()
            do {
                guard let vminitd = agent as? Vminitd else {
                    throw ContainerizationError(.unsupported, message: "the VM's agent cannot copy files")
                }
                let result = try await body(vminitd, vm)
                try await agent.close()
                return result
            } catch {
                try? await agent.close()
                throw error
            }
        }
    }
}

/// The copies running in a container, so that its stop can end them before it unmounts the
/// root filesystem they write into.
final class ActiveCopies: Sendable {
    private struct State {
        var tasks: [UUID: Task<Void, any Error>] = [:]
        /// Set by `cancelAll` until `reopen`: the container is stopping, and a copy that
        /// arrives now would hold a file open in a root filesystem about to be unmounted.
        var closed = false
    }

    private let state = Mutex(State())

    /// What a copy ended by a stop reports. vminitd 0.47.0 writes a copy in straight into
    /// its destination, so an interrupted copy leaves it partly written.
    static let stoppedMessage = "the container stopped during the copy, which may have left the destination partly written"

    var count: Int { state.withLock { $0.tasks.count } }

    /// Run `operation` as a copy that `cancelAll` ends. Cancelling the caller cancels it too.
    /// A copy that `cancelAll` ended, or that arrives after it, fails with `invalidState`.
    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let id = UUID()
        let task: Task<Void, any Error>? = state.withLock { state in
            guard !state.closed else { return nil }
            let task = Task { try await operation() }
            state.tasks[id] = task
            return task
        }
        guard let task else {
            throw ContainerizationError(.invalidState, message: "cannot copy: the container is stopping")
        }
        defer { state.withLock { _ = $0.tasks.removeValue(forKey: id) } }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError where !Task.isCancelled {
            throw ContainerizationError(.invalidState, message: Self.stoppedMessage)
        }
    }

    /// Refuse new copies, cancel every running one and wait for each to end.
    func cancelAll() async {
        let running = state.withLock { state in
            state.closed = true
            return Array(state.tasks.values)
        }
        for task in running { task.cancel() }
        for task in running { _ = await task.result }
    }

    /// Take copies again: the container has been made anew.
    func reopen() {
        state.withLock { $0.closed = false }
    }
}
