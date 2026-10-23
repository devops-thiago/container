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
import ContainerizationArchive
import ContainerizationError
import Foundation
import GRPCCore
import Synchronization
import SystemPackage

/// What a copy into a container that has not started needs of the VM's agent.
protocol GuestCopyAgent: Sendable {
    /// The file at `path` resolved as if `root` were `/` and confined to it, or `nil` when there
    /// is nothing there.
    func identity(root: String, path: String) async throws -> GuestFileIdentity?
    /// Copy `source` on the host to `path` under `root`. The agent resolves `path` confined to
    /// `root` (openat2 with `RESOLVE_IN_ROOT`): a symlink or `..` in the image is followed as
    /// if `root` were `/`, so the write can never land outside it. Directories travel as an
    /// archive; files travel as bytes with their owner in the RPC. The guest opens the file
    /// without replacing a directory or final symlink. Explicit archive uploads retain
    /// archive replacement semantics and enforce their requested type-protection policy.
    /// `owner`, when given, owns everything copied (`copyUIDGID`).
    func copy(from source: URL, isDirectory: Bool, root: String, path: String, mode: UInt32, createParents: Bool, owner: CopyOwner?) async throws
    /// Copy `path` under `root` to `destination` on the host: a directory's contents into
    /// `destination`, a regular file as `destination`. The agent resolves `path` confined to
    /// `root` and refuses anything else. `recordOwners` keeps each file's owner in the
    /// container on its copy (`CopyOwner.record(_:at:)`), which the host's own ownership
    /// cannot hold: the engine is not root.
    func copyOut(root: String, path: String, to destination: URL, recordOwners: Bool) async throws
}

extension GuestCopyAgent {
    func copyOut(root: String, path: String, to destination: URL) async throws {
        try await copyOut(root: root, path: path, to: destination, recordOwners: false)
    }
}

/// Copies into a container whose VM is up and whose root filesystem is mounted, but whose init
/// process has not started: between `LinuxContainer.create()` and `start()`. A Docker client
/// copies files into a created container then (Testcontainers' `withCopyToContainer`), and
/// containerization's own `copyIn` takes only a started container.
///
/// The copy goes through the agent's own copy, anchored at the container's root filesystem in
/// the VM, which confines every path to it. The destination is resolved as containerization's
/// `copyIn` resolves it: into an existing directory under the source's name, else at the path
/// itself.
enum PrestartCopy {
    static func copyIn(
        from source: URL, to destination: String, mode: UInt32, createParents: Bool, rootfs: String, owner: CopyOwner? = nil,
        agent: some GuestCopyAgent
    ) async throws {
        let path = FilePath(destination)
        guard path.isAbsolute else {
            throw ContainerizationError(.invalidArgument, message: "copyIn: destination must be absolute: \(destination)")
        }
        guard !path.components.contains(where: { $0.kind == .parentDirectory }) else {
            throw ContainerizationError(.invalidArgument, message: "copyIn: destination must not climb with '..': \(destination)")
        }
        let normalized = path.lexicallyNormalized()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw ContainerizationError(.notFound, message: "copyIn: source not found '\(source.path)'")
        }
        let target: FilePath
        switch try await agent.identity(root: rootfs, path: normalized.string) {
        case .some(let existing) where existing.isDirectory:
            target = normalized.appending(source.lastPathComponent)
        case .some:
            guard !isDirectory.boolValue else {
                throw ContainerizationError(.invalidArgument, message: "copyIn: cannot copy directory over existing file: \(normalized)")
            }
            target = normalized
        case .none:
            target = normalized
        }
        try await agent.copy(
            from: source, isDirectory: isDirectory.boolValue, root: rootfs, path: target.string, mode: mode, createParents: createParents,
            owner: owner)
    }
}

/// `GuestCopyAgent` over vminitd, with the vsock connection the copy streams on.
struct VminitdCopyAgent: GuestCopyAgent {
    let agent: Vminitd
    let vm: any VirtualMachineInstance
    var noOverwriteDirNonDir = false
    var copyAsArchive = false

    /// Host vsock ports for these copies: a range of their own, apart from containerization's
    /// per-container allocator (which starts at 0x1000_0000), taken in turn.
    private static let nextPort = Mutex<UInt32>(0)
    static let portBase: UInt32 = 0x5353_0000

    static func port() -> UInt32 {
        nextPort.withLock { next in
            defer { next = (next + 1) % 0x1_0000 }
            return portBase + next
        }
    }

    func identity(root: String, path: String) async throws -> GuestFileIdentity? {
        try await VminitdMountAgent(agent: agent).identity(root: root, path: path)
    }

    func copy(from source: URL, isDirectory: Bool, root: String, path: String, mode: UInt32, createParents: Bool, owner: CopyOwner?) async throws {
        let fileOwner = isDirectory ? nil : try Self.fileOwner(source, override: owner)
        let port = Self.port()
        let listener = try vm.listen(port)
        defer { try? listener.finish() }
        try await Self.runCopyTasks(
            rpc: {
                try await Self.requestCopy(
                    agent: agent, root: root, path: path, port: port, mode: mode, createParents: createParents,
                    isDirectory: isDirectory, owner: fileOwner, noOverwriteDirNonDir: noOverwriteDirNonDir, copyAsArchive: copyAsArchive)
            },
            transfer: {
                guard let connection = await listener.first(where: { _ in true }) else {
                    throw ContainerizationError(.internalError, message: "copyIn: the VM did not connect for the copy")
                }
                try listener.finish()
                try await Self.send(
                    source, isDirectory: isDirectory, name: isDirectory ? "." : (FilePath(path).lastComponent?.string ?? source.lastPathComponent),
                    mode: mode, owner: owner, copyAsArchive: copyAsArchive, to: connection)
            },
            closeListener: { try? listener.finish() })
    }

    static func fileOwner(_ source: URL, override: CopyOwner?) throws -> CopyOwner {
        var info = stat()
        guard stat(source.path, &info) == 0 else {
            throw ContainerizationError(.notFound, message: "copyIn: cannot stat source '\(source.path)'")
        }
        return CopyArchive.owner(of: source.path, info: info, override: override)
    }

    /// The separate owned-file operation makes an old guest reject the request before any
    /// write. Never fall back to a plain copy that silently loses the requested ownership.
    static func requestCopy(
        agent: Vminitd, root: String, path: String, port: UInt32, mode: UInt32, createParents: Bool,
        isDirectory: Bool, owner: CopyOwner?, noOverwriteDirNonDir: Bool = false, copyAsArchive: Bool = false
    ) async throws {
        guard isDirectory || owner != nil else {
            throw ContainerizationError(.invalidArgument, message: "copyIn: file ownership is required")
        }
        let archive = isDirectory || copyAsArchive
        let destination = copyAsArchive && !isDirectory ? FilePath(path).removingLastComponent().string : path
        let direction: Com_Apple_Containerization_Sandbox_V3_CopyRequest.Direction =
            archive ? (noOverwriteDirNonDir ? .copyInCheckedArchive : .copyIn) : .copyInOwnedFile
        do {
            try await agent.copy(
                direction: direction, root: root, path: destination, vsockPort: port,
                mode: mode, createParents: createParents, isArchive: archive,
                ownerUID: archive ? nil : owner?.uid, ownerGID: archive ? nil : owner?.gid)
        } catch let error as RPCError
            where error.code == .invalidArgument
            && error.message == "copy: unrecognized direction \(direction.rawValue)"
        {
            throw ContainerizationError(
                .unsupported,
                message:
                    "This container's guest agent needs an update for safe copies. Stop it, run 'container system upgrade-guest <container>', then start it again. This replaces the guest agent and preserves workload data.",
                cause: error)
        }
    }

    static func runCopyTasks(
        rpc: @escaping @Sendable () async throws -> Void,
        transfer: @escaping @Sendable () async throws -> Void,
        closeListener: @escaping @Sendable () -> Void
    ) async throws {
        try Task.checkCancellation()
        defer { closeListener() }
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(operation: rpc)
                group.addTask(operation: transfer)
                do {
                    while try await group.next() != nil {}
                } catch {
                    // Closing the listener must happen before the group waits for its
                    // remaining child, which may still be waiting for a guest connection.
                    closeListener()
                    group.cancelAll()
                    try Task.checkCancellation()
                    throw error
                }
            }
        } onCancel: {
            closeListener()
        }
    }

    func copyOut(root: String, path: String, to destination: URL, recordOwners: Bool) async throws {
        let port = Self.port()
        let listener = try vm.listen(port)
        defer { try? listener.finish() }
        let (metadata, metadataContinuation) = AsyncStream.makeStream(of: Vminitd.CopyMetadata.self)
        try await Self.runCopyTasks(
            rpc: {
                defer { metadataContinuation.finish() }
                let announced = Mutex(false)
                try await agent.copy(
                    direction: .copyOut, root: root, path: path, vsockPort: port,
                    onMetadata: { item in
                        announced.withLock { $0 = true }
                        metadataContinuation.yield(item)
                        metadataContinuation.finish()
                    })
                guard announced.withLock({ $0 }) else {
                    throw ContainerizationError(.internalError, message: "copyOut: the VM sent no metadata for the copy")
                }
            },
            transfer: {
                // Without metadata the RPC failed, and its error is the one to report.
                guard let metadata = await metadata.first(where: { _ in true }) else { return }
                guard let connection = await listener.first(where: { _ in true }) else {
                    throw ContainerizationError(.internalError, message: "copyOut: the VM did not connect for the copy")
                }
                try listener.finish()
                try await Self.receive(to: destination, isArchive: metadata.isArchive, recordOwners: recordOwners, from: connection)
                if recordOwners, !metadata.isArchive, let info = try? await agent.stat(root: root, path: path) {
                    // A file comes as its bytes alone: its owner is the agent's stat of it. As
                    // for an archive's entries, an owner that cannot be noted leaves the copy,
                    // already whole, as the host has it.
                    try? CopyOutOwners.record(CopyOwner(uid: info.uid, gid: info.gid), at: destination.path(percentEncoded: false))
                }
            },
            closeListener: { try? listener.finish() })
    }

    /// Streams native files as bytes; directories and explicit archive uploads retain
    /// archive entries and ownership, off the cooperative pool.
    static func send(_ source: URL, isDirectory: Bool, name: String, mode: UInt32, owner: CopyOwner?, copyAsArchive: Bool = false, to connection: FileHandle) async throws {
        try await transfer(over: connection) { fd in
            if isDirectory || copyAsArchive {
                try CopyArchive.write(source, isDirectory: isDirectory, name: name, mode: mode, owner: owner, to: fd)
            } else {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
        }
    }

    /// Reads what the guest sends on `connection` into `destination` off the cooperative pool,
    /// and closes it: an archive is unpacked into `destination`, a file's bytes replace it.
    /// With `recordOwners`, each entry of an archive keeps the owner it names
    /// (`CopyOutOwners.unpack`).
    static func receive(to destination: URL, isArchive: Bool, recordOwners: Bool = false, from connection: FileHandle) async throws {
        try await transfer(over: connection) { fd in
            if isArchive {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let input = FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true)
                if recordOwners {
                    try CopyOutOwners.unpack(input, into: destination)
                } else {
                    let reader = try ArchiveReader(format: .pax, filter: .gzip, fileHandle: input)
                    _ = try reader.extractContents(to: destination)
                }
            } else {
                let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
                guard output != -1 else {
                    throw ContainerizationError(
                        .internalError, message: "copyOut: failed to open '\(destination.path)': \(String(cString: strerror(errno)))")
                }
                let file = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    try file.write(contentsOf: chunk)
                }
                try file.close()
            }
        }
    }

    static let chunkSize = 1 << 20

    /// Runs `body` with `connection`'s descriptor on a thread of its own, off the cooperative
    /// pool, then closes `connection`. Cancelling the caller shuts the connection down, so a
    /// read or write blocked on the guest returns at once and the guest's end sees the copy
    /// end; without it a cancelled copy streamed on to the end of its file.
    static func transfer(over connection: FileHandle, _ body: @escaping @Sendable (Int32) throws -> Void) async throws {
        let open = Mutex(true)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let thread = Thread {
                    let result = Result { try body(connection.fileDescriptor) }
                    open.withLock { isOpen in
                        isOpen = false
                        connection.closeFile()
                    }
                    continuation.resume(with: result)
                }
                thread.name = "copy transfer"
                thread.start()
            }
        } onCancel: {
            open.withLock { isOpen in
                if isOpen { _ = shutdown(connection.fileDescriptor, SHUT_RDWR) }
            }
        }
        // A read ended by the shutdown looks like the end of the stream: still a cancelled copy.
        try Task.checkCancellation()
    }
}
