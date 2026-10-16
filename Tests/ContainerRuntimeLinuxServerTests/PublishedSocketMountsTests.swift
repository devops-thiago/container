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
import ContainerizationError
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

@testable import ContainerRuntimeLinuxServer

struct PublishedSocketMountsTests {
    static let rootfs = "/run/container/ctr/rootfs"

    static func socket(_ containerPath: String, host: String = "/tmp/host.sock") throws -> PublishSocket {
        try PublishSocket(containerPath: FilePath(containerPath), hostPath: FilePath(host))
    }

    static func plan(
        _ mounts: [Filesystem],
        sockets: [String],
        otherDestinations: [String] = []
    ) throws -> (inGuest: [String], inContainer: [String]) {
        let plan = PublishedSocketMounts(mounts: mounts, sockets: try sockets.map { try socket($0) }, otherDestinations: otherDestinations)
        return (plan.inGuest.map(\.destination), plan.inContainer.map(\.destination))
    }

    static let share = Filesystem.virtiofs(source: "/Users/me/project", destination: "/run/buildkit", options: [])

    // MARK: - Which tmpfs moves

    @Test func theTmpfsHoldingAPublishedSocketIsMountedInTheGuest() throws {
        let plan = try Self.plan([.tmpfs(destination: "/run", options: [])], sockets: ["/run/buildkit/buildkitd.sock"])
        #expect(plan.inGuest == ["/run"])
        #expect(plan.inContainer.isEmpty)
    }

    @Test func withoutAPublishedSocketEveryMountStaysWithTheContainer() throws {
        let mounts: [Filesystem] = [.tmpfs(destination: "/run", options: []), .tmpfs(destination: "/tmp", options: [])]
        let plan = try Self.plan(mounts, sockets: [])
        #expect(plan.inGuest.isEmpty)
        #expect(plan.inContainer == ["/run", "/tmp"])
    }

    @Test func aTmpfsElsewhereStaysWithTheContainer() throws {
        let mounts: [Filesystem] = [.tmpfs(destination: "/srv", options: []), .tmpfs(destination: "/run", options: [])]
        let plan = try Self.plan(mounts, sockets: ["/run/app.sock"])
        #expect(plan.inGuest == ["/run"])
        #expect(plan.inContainer == ["/srv"])
    }

    @Test func aSocketOnTheRootFilesystemMovesNothing() throws {
        let plan = try Self.plan([.tmpfs(destination: "/tmp", options: [])], sockets: ["/var/run/app.sock"])
        #expect(plan.inGuest.isEmpty)
    }

    @Test func destinationsAreComparedByComponentNotByText() throws {
        // `/ru` is a string prefix of `/run/app.sock` but not a directory above it.
        let plan = try Self.plan([.tmpfs(destination: "/ru", options: [])], sockets: ["/run/app.sock"])
        #expect(plan.inGuest.isEmpty)
        #expect(plan.inContainer == ["/ru"])
    }

    @Test func pathsAreNormalisedBeforeComparing() throws {
        let plan = try Self.plan([.tmpfs(destination: "/run/", options: [])], sockets: ["/run/./buildkit/../buildkit/buildkitd.sock"])
        #expect(plan.inGuest == ["/run/"])
    }

    @Test func aSocketAtTheMountItselfMovesNothing() throws {
        let plan = try Self.plan([.tmpfs(destination: "/run/app.sock", options: [])], sockets: ["/run/app.sock"])
        #expect(plan.inGuest.isEmpty)
    }

    @Test func onlyTheInnermostMountOverTheSocketCounts() throws {
        // The socket is on the share, which the OCI runtime mounts: moving `/run` would not help.
        let plan = try Self.plan([.tmpfs(destination: "/run", options: []), Self.share], sockets: ["/run/buildkit/buildkitd.sock"])
        #expect(plan.inGuest.isEmpty)
        #expect(plan.inContainer == ["/run", "/run/buildkit"])
    }

    @Test func aTmpfsUnderAnotherMountStaysWithTheContainer() throws {
        // The share at `/run` would be mounted over a tmpfs moved to `/run/buildkit`.
        let share = Filesystem.virtiofs(source: "/Users/me/run", destination: "/run", options: [])
        let plan = try Self.plan([share, .tmpfs(destination: "/run/buildkit", options: [])], sockets: ["/run/buildkit/buildkitd.sock"])
        #expect(plan.inGuest.isEmpty)
        #expect(plan.inContainer == ["/run", "/run/buildkit"])
    }

    @Test func aTmpfsUnderOrAtADefaultMountStaysWithTheContainer() throws {
        let under = try Self.plan([.tmpfs(destination: "/dev/shm/x", options: [])], sockets: ["/dev/shm/x/a.sock"], otherDestinations: ["/dev"])
        #expect(under.inGuest.isEmpty)
        let at = try Self.plan([.tmpfs(destination: "/dev/shm", options: [])], sockets: ["/dev/shm/a.sock"], otherDestinations: ["/dev/shm"])
        #expect(at.inGuest.isEmpty)
        // Control: a default mount elsewhere does not stop it.
        let elsewhere = try Self.plan([.tmpfs(destination: "/run", options: [])], sockets: ["/run/a.sock"], otherDestinations: ["/dev", "/dev/shm"])
        #expect(elsewhere.inGuest == ["/run"])
    }

    @Test func aSecondMountAtTheSamePlaceKeepsTheTmpfsWithTheContainer() throws {
        let share = Filesystem.virtiofs(source: "/Users/me/run", destination: "/run", options: [])
        // The last mount at a place is on top, so it is the one the socket is on.
        let shareLast = try Self.plan([.tmpfs(destination: "/run", options: []), share], sockets: ["/run/a.sock"])
        #expect(shareLast.inGuest.isEmpty)
        // A tmpfs listed after the share is still mounted in the container with the share at
        // the same place, which the OCI runtime would mount over the moved one: it stays too.
        let tmpfsLast = try Self.plan([share, .tmpfs(destination: "/run", options: [])], sockets: ["/run/a.sock"])
        #expect(tmpfsLast.inGuest.isEmpty)
    }

    @Test func nestedTmpfsMountsWithSocketsBothMoveParentsFirst() throws {
        let mounts: [Filesystem] = [.tmpfs(destination: "/run/inner", options: []), .tmpfs(destination: "/run", options: [])]
        let plan = try Self.plan(mounts, sockets: ["/run/inner/a.sock", "/run/b.sock"])
        #expect(plan.inGuest == ["/run", "/run/inner"])
        #expect(plan.inContainer.isEmpty)
    }

    @Test func anInnerTmpfsUnderAnOuterOneThatStaysAlsoStays() throws {
        // `/run` holds no socket and stays with the OCI runtime, which would mount it over a
        // moved `/run/inner`.
        let mounts: [Filesystem] = [.tmpfs(destination: "/run", options: []), .tmpfs(destination: "/run/inner", options: [])]
        let plan = try Self.plan(mounts, sockets: ["/run/inner/a.sock"])
        #expect(plan.inGuest.isEmpty)
    }

    @Test func whatCoversAnOuterTmpfsKeepsTheInnerOneToo() throws {
        let share = Filesystem.virtiofs(source: "/Users/me/data", destination: "/data", options: [])
        let mounts: [Filesystem] = [share, .tmpfs(destination: "/data/run", options: []), .tmpfs(destination: "/data/run/x", options: [])]
        let plan = try Self.plan(mounts, sockets: ["/data/run/a.sock", "/data/run/x/b.sock"])
        #expect(plan.inGuest.isEmpty)
        #expect(plan.inContainer == ["/data", "/data/run", "/data/run/x"])
    }

    @Test func theOtherMountsKeepTheirOrder() throws {
        let mounts: [Filesystem] = [
            .tmpfs(destination: "/b", options: []), .tmpfs(destination: "/run", options: []), .tmpfs(destination: "/a", options: []),
        ]
        let plan = try Self.plan(mounts, sockets: ["/run/a.sock"])
        #expect(plan.inContainer == ["/b", "/a"])
    }

    @Test func theGuestRootFilesystemIsContainerizationsPath() {
        #expect(PublishedSocketMounts.guestRootfs(containerID: "buildkit") == "/run/container/buildkit/rootfs")
    }

    // MARK: - Mounting in the guest

    /// A VM's files as vminitd sees them: each path resolved in the VM and confined to the root
    /// filesystem. A path missing from both is absent; `makeDirectory` adds it to both.
    actor FakeAgent: GuestMountAgent {
        var confined: [String: GuestFileIdentity]
        var resolved: [String: GuestFileIdentity]
        var failMakeDirectory = false
        var created: [String] = []
        var mounted: [ContainerizationOCI.Mount] = []
        var unmounted: [(String, Int32)] = []
        var failUnmount: Set<String> = []
        private var nextInode: UInt64 = 1000

        init(confined: [String: GuestFileIdentity] = [:], resolved: [String: GuestFileIdentity] = [:]) {
            self.confined = confined
            self.resolved = resolved
        }

        func identity(root: String, path: String) async throws -> GuestFileIdentity? {
            root == "/" ? resolved[path] : confined[path]
        }

        func makeDirectory(path: String) async throws {
            if failMakeDirectory { throw POSIXError(.EEXIST) }
            created.append(path)
            nextInode += 1
            let identity = GuestFileIdentity(device: 1, inode: nextInode, isDirectory: true)
            resolved[path] = identity
            confined[String(path.dropFirst(PublishedSocketMountsTests.rootfs.count))] = identity
        }

        func mount(_ mount: ContainerizationOCI.Mount) async throws {
            mounted.append(mount)
        }

        func unmount(path: String, flags: Int32) async throws {
            if failUnmount.contains(path) { throw POSIXError(.EINVAL) }
            unmounted.append((path, flags))
        }

        func setFailMakeDirectory() { failMakeDirectory = true }
        func setFailUnmount(_ path: String) { failUnmount.insert(path) }
    }

    static let directory = GuestFileIdentity(device: 1, inode: 10, isDirectory: true)

    /// `/run` in the image, the same file both ways.
    static func agentWithRun() -> FakeAgent {
        FakeAgent(confined: ["/run": directory], resolved: ["\(rootfs)/run": directory])
    }

    @Test func anExistingDirectoryIsMountedOverWithTheTmpfsOptions() async throws {
        let agent = Self.agentWithRun()
        try await PublishedSocketMounts.mount([.tmpfs(destination: "/run", options: ["size=64m", "mode=755"])], rootfs: Self.rootfs, agent: agent)
        let mounted = await agent.mounted
        #expect(mounted.count == 1)
        #expect(mounted.first?.type == "tmpfs")
        #expect(mounted.first?.source == "tmpfs")
        #expect(mounted.first?.destination == "\(Self.rootfs)/run")
        #expect(mounted.first?.options == ["size=64m", "mode=755"])
        #expect(await agent.created.isEmpty)
    }

    @Test func missingDirectoriesAreCreatedOneAtATime() async throws {
        let agent = Self.agentWithRun()
        let target = try await PublishedSocketMounts.prepareMountpoint("/run/a/b", rootfs: Self.rootfs, agent: agent)
        #expect(target == "\(Self.rootfs)/run/a/b")
        #expect(await agent.created == ["\(Self.rootfs)/run/a", "\(Self.rootfs)/run/a/b"])
    }

    @Test func aPathThatLeavesTheRootFilesystemIsRefused() async throws {
        // `/run` is an absolute symlink: confined it is the image's `/var/run`, in the VM it is
        // the VM's own `/var/run`.
        let agent = FakeAgent(
            confined: ["/run": GuestFileIdentity(device: 1, inode: 10, isDirectory: true)],
            resolved: ["\(Self.rootfs)/run": GuestFileIdentity(device: 2, inode: 77, isDirectory: true)])
        await #expect(throws: ContainerizationError.self) {
            try await PublishedSocketMounts.mount([.tmpfs(destination: "/run", options: [])], rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.mounted.isEmpty)
    }

    @Test func aPathOnlyOneSideFindsIsRefused() async throws {
        // A symlink dangling in the image that points at something in the VM.
        let agent = FakeAgent(confined: [:], resolved: ["\(Self.rootfs)/run": Self.directory])
        await #expect(throws: ContainerizationError.self) {
            _ = try await PublishedSocketMounts.prepareMountpoint("/run", rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.created.isEmpty)
    }

    @Test func aFileInTheWayIsRefused() async throws {
        let file = GuestFileIdentity(device: 1, inode: 11, isDirectory: false)
        let agent = FakeAgent(confined: ["/run": file], resolved: ["\(Self.rootfs)/run": file])
        await #expect(throws: ContainerizationError.self) {
            _ = try await PublishedSocketMounts.prepareMountpoint("/run/x", rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.created.isEmpty)
    }

    @Test func aDirectoryThatCannotBeCreatedFailsTheMount() async throws {
        // A dangling symlink: neither side finds it, and creating a directory there fails.
        let agent = FakeAgent()
        await agent.setFailMakeDirectory()
        await #expect(throws: (any Error).self) {
            try await PublishedSocketMounts.mount([.tmpfs(destination: "/run", options: [])], rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.mounted.isEmpty)
    }

    @Test func detachingGoesChildrenFirstAndCollectsFailures() async throws {
        let agent = FakeAgent()
        await agent.setFailUnmount("\(Self.rootfs)/srv")
        let mounts: [Filesystem] = [
            .tmpfs(destination: "/run", options: []), .tmpfs(destination: "/run/inner/", options: []), .tmpfs(destination: "/srv", options: []),
        ]
        let errors = await PublishedSocketMounts.unmount(mounts, rootfs: Self.rootfs, agent: agent)
        #expect(errors.count == 1)
        let unmounted = await agent.unmounted
        #expect(unmounted.map(\.0) == ["\(Self.rootfs)/run/inner", "\(Self.rootfs)/run"])
        #expect(unmounted.allSatisfy { $0.1 == PublishedSocketMounts.detach })
        #expect(PublishedSocketMounts.detach == 2)
    }

    // MARK: - Host permissions

    /// A unix socket bound at a fresh path, created with the process umask.
    static func boundSocket() throws -> (path: String, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "psm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "s.sock").path(percentEncoded: false)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        return (
            path,
            {
                close(fd)
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    static func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test func theHostEndGetsTheSocketsPermissions() throws {
        let (path, cleanup) = try Self.boundSocket()
        defer { cleanup() }
        chmod(path, 0o755)
        try PublishSocket(containerPath: "/run/a.sock", hostPath: FilePath(path), permissions: FilePermissions(rawValue: 0o600)).applyHostPermissions()
        #expect(Self.mode(path) == 0o600)
    }

    @Test func withoutPermissionsTheHostEndIsLeftAlone() throws {
        let (path, cleanup) = try Self.boundSocket()
        defer { cleanup() }
        chmod(path, 0o755)
        try PublishSocket(containerPath: "/run/a.sock", hostPath: FilePath(path)).applyHostPermissions()
        #expect(Self.mode(path) == 0o755)
    }

    @Test func aMissingHostEndIsAnError() throws {
        let socket = try PublishSocket(
            containerPath: "/run/a.sock", hostPath: FilePath("/nonexistent-\(UUID().uuidString)/a.sock"), permissions: FilePermissions(rawValue: 0o600))
        #expect(throws: (any Error).self) { try socket.applyHostPermissions() }
    }
}
