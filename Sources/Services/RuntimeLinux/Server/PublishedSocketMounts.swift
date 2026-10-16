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
import ContainerizationOCI
import Foundation
import SystemPackage

/// The tmpfs mounts that hold a published socket, which the runtime mounts in the VM itself
/// instead of leaving them to the OCI runtime.
///
/// The guest end of a published socket's relay is vminitd. On every connection it connects to
/// the socket at `<root filesystem>/<container path>` from its own mount namespace. The OCI
/// runtime mounts a container's tmpfs in the container's mount namespace, which is a slave of
/// vminitd's, so nothing created on that tmpfs ever appears at that path: the socket exists in
/// the container, but every connection to the host end ends at once (vminitd logs ENOENT).
///
/// A tmpfs that vminitd mounts at `<root filesystem>/<destination>` before the container
/// starts is carried into the container by the OCI runtime's recursive bind of the root
/// filesystem. The container and the relay then see one filesystem, and the socket is where
/// the relay looks. Only a tmpfs that is the innermost mount over a published socket is moved,
/// and only when no other mount lies over it; every other mount is left to the OCI runtime.
struct PublishedSocketMounts {
    /// The tmpfs mounts for the VM to mount, parents first.
    let inGuest: [Filesystem]
    /// Every other mount, in its order, for the OCI runtime.
    let inContainer: [Filesystem]

    /// Where containerization 0.47.0 mounts a container's root filesystem in the VM. It is
    /// containerization's convention, not an API (`LinuxContainer.guestRootfsPath`, which is
    /// private); the hosts refresh writes `/etc/hosts` under it too.
    static func guestRootfs(containerID: String) -> String {
        "/run/container/\(containerID)/rootfs"
    }

    /// Plan `mounts` for `sockets`.
    ///
    /// - Parameters:
    ///   - mounts: the container's own mounts, in their order.
    ///   - sockets: the sockets the container publishes to the host.
    ///   - otherDestinations: where the OCI runtime mounts anything else (`/dev`, `/dev/shm`
    ///     and the rest of containerization's defaults). A tmpfs under one of these, or at one,
    ///     would be covered by it and so is not moved.
    init(mounts: [Filesystem], sockets: [PublishSocket], otherDestinations: [String] = []) {
        let destinations = mounts.map { FilePath($0.destination).lexicallyNormalized() }
        let others = otherDestinations.map { FilePath($0).lexicallyNormalized() }

        // The innermost mount over each socket; among mounts at one place, the last, which
        // the OCI runtime mounts on top.
        var moved = Set<Int>()
        for socket in sockets {
            let path = socket.containerPath.lexicallyNormalized()
            var innermost: Int?
            for (index, destination) in destinations.enumerated() where Self.isAncestor(destination, of: path) {
                if let current = innermost, destinations[current].components.count > destination.components.count {
                    continue
                }
                innermost = index
            }
            if let innermost, mounts[innermost].isTmpfs {
                moved.insert(innermost)
            }
        }

        // A moved tmpfs is mounted before the container starts, so anything the OCI runtime
        // mounts at it or over it would hide it. Whatever covers a moved tmpfs also covers
        // every mount under it, so one pass drops all that are covered.
        let candidates = moved
        moved = candidates.filter { index in
            let destination = destinations[index]
            let coveredByMount = destinations.indices.contains { other in
                guard !candidates.contains(other) else { return false }
                return destinations[other] == destination || Self.isAncestor(destinations[other], of: destination)
            }
            let coveredByDefault = others.contains { $0 == destination || Self.isAncestor($0, of: destination) }
            return !coveredByMount && !coveredByDefault
        }

        self.inGuest = moved.sorted { lhs, rhs in
            let left = destinations[lhs].components.count
            let right = destinations[rhs].components.count
            return left == right ? lhs < rhs : left < right
        }.map { mounts[$0] }
        self.inContainer = mounts.indices.filter { !moved.contains($0) }.map { mounts[$0] }
    }

    /// Whether `ancestor` is a directory above `path`, component by component.
    static func isAncestor(_ ancestor: FilePath, of path: FilePath) -> Bool {
        ancestor != path && path.starts(with: ancestor)
    }
}

/// A file's identity in the VM, as vminitd reports it.
struct GuestFileIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var isDirectory: Bool
}

/// What mounting a tmpfs for a published socket asks of the VM's agent.
protocol GuestMountAgent: Sendable {
    /// The file at `path` resolved as if `root` were `/` and confined to it, or `nil` when there
    /// is nothing there.
    func identity(root: String, path: String) async throws -> GuestFileIdentity?
    /// Create the directory at `path`, whose parent exists. Fails when something is there.
    func makeDirectory(path: String) async throws
    func mount(_ mount: ContainerizationOCI.Mount) async throws
    func unmount(path: String, flags: Int32) async throws
}

/// The real agent, vminitd.
struct VminitdMountAgent: GuestMountAgent {
    let agent: Vminitd

    func identity(root: String, path: String) async throws -> GuestFileIdentity? {
        do {
            let stat = try await agent.stat(root: root, path: path)
            return GuestFileIdentity(device: stat.dev, inode: stat.ino, isDirectory: stat.mode & UInt32(S_IFMT) == UInt32(S_IFDIR))
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
    }

    func makeDirectory(path: String) async throws {
        try await agent.mkdir(path: path, all: false, perms: 0o755)
    }

    func mount(_ mount: ContainerizationOCI.Mount) async throws {
        try await agent.mount(mount)
    }

    func unmount(path: String, flags: Int32) async throws {
        try await agent.umount(path: path, flags: flags)
    }
}

extension PublishedSocketMounts {
    /// Linux's `MNT_DETACH`: unmount now, even while the filesystem is in use.
    static let detach: Int32 = 2

    /// Mount each of `mounts` in the VM at its place under `rootfs`, parents first.
    ///
    /// vminitd resolves a path in the VM, where an absolute symlink in the container's root
    /// filesystem points outside it. So each directory on the way is checked to be the same
    /// file whether resolved in the VM or confined to the root filesystem, and the missing
    /// ones are created one at a time and checked the same way. Nothing in the container is
    /// running yet, so nothing can change them in between. A destination that leaves the root
    /// filesystem is refused, and the start fails rather than publish nothing.
    static func mount(_ mounts: [Filesystem], rootfs: String, agent: some GuestMountAgent) async throws {
        for mount in mounts {
            let target = try await prepareMountpoint(mount.destination, rootfs: rootfs, agent: agent)
            try await agent.mount(
                ContainerizationOCI.Mount(type: "tmpfs", source: "tmpfs", destination: target, options: mount.options))
        }
    }

    /// Detach each of `mounts` from under `rootfs`, children first. The container's own view
    /// is unaffected; containerization's stop can then unmount the root filesystem, which it
    /// cannot while anything is mounted under it.
    ///
    /// - Returns: the errors, one per mount that could not be detached.
    static func unmount(_ mounts: [Filesystem], rootfs: String, agent: some GuestMountAgent) async -> [any Error] {
        var errors: [any Error] = []
        for mount in mounts.reversed() {
            let target = rootfs + FilePath(mount.destination).lexicallyNormalized().string
            do {
                try await agent.unmount(path: target, flags: detach)
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    /// Make sure `destination` is a directory inside `rootfs`, creating what is missing, and
    /// return its path in the VM.
    static func prepareMountpoint(_ destination: String, rootfs: String, agent: some GuestMountAgent) async throws -> String {
        let normalized = FilePath(destination).lexicallyNormalized()
        var inRoot = FilePath("/")
        for component in normalized.components {
            inRoot.append(component)
            let inVM = rootfs + inRoot.string
            var confined = try await agent.identity(root: rootfs, path: inRoot.string)
            var resolved = try await agent.identity(root: "/", path: inVM)
            if confined == nil && resolved == nil {
                try await agent.makeDirectory(path: inVM)
                confined = try await agent.identity(root: rootfs, path: inRoot.string)
                resolved = try await agent.identity(root: "/", path: inVM)
            }
            guard let confined, let resolved, confined == resolved, confined.isDirectory else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "cannot publish a socket from the tmpfs at \(normalized): \(inRoot) is not a directory inside the container's root filesystem"
                )
            }
        }
        return rootfs + normalized.string
    }
}

extension PublishSocket {
    /// Give the host end the socket's permissions.
    ///
    /// containerization creates the host end of a socket published out of a container with
    /// the process umask, and applies `permissions` only to sockets it creates in the guest,
    /// so without this a published socket is readable and writable by whoever can reach the
    /// folder it is in.
    func applyHostPermissions() throws {
        guard let permissions else { return }
        guard chmod(hostPath.string, permissions.rawValue) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
