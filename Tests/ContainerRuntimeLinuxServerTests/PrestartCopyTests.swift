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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

struct PrestartCopyTests {
    static let rootfs = PublishedSocketMounts.guestRootfs(containerID: "ctr")

    /// The agent as the copy sees it: what is in the root filesystem, by confined path, and
    /// the copies asked for.
    actor FakeAgent: GuestCopyAgent {
        struct Copy: Equatable {
            let isDirectory: Bool
            let root: String
            let path: String
            let mode: UInt32
            let createParents: Bool
        }

        var entries: [String: GuestFileIdentity]
        private(set) var copies: [Copy] = []
        private(set) var identityRoots: [String] = []

        init(_ entries: [String: GuestFileIdentity] = [:]) {
            self.entries = entries
        }

        func identity(root: String, path: String) async throws -> GuestFileIdentity? {
            identityRoots.append(root)
            return entries[path]
        }

        func copy(from source: URL, isDirectory: Bool, root: String, path: String, mode: UInt32, createParents: Bool) async throws {
            copies.append(Copy(isDirectory: isDirectory, root: root, path: path, mode: mode, createParents: createParents))
        }
    }

    static let directory = GuestFileIdentity(device: 1, inode: 2, isDirectory: true)
    static let file = GuestFileIdentity(device: 1, inode: 3, isDirectory: false)

    final class Source {
        let top = FileManager.default.temporaryDirectory.appending(path: "prestart-\(UUID().uuidString.prefix(8))")
        var file: URL { top.appending(path: "hello.txt") }
        var directory: URL { top.appending(path: "smoke") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("hello\n".utf8).write(to: file)
        }

        deinit { try? FileManager.default.removeItem(at: top) }
    }

    @Test("a copy into an existing directory lands under the source's name, anchored at the root filesystem")
    func intoDirectory() async throws {
        let source = try Source()
        let agent = FakeAgent(["/": Self.directory])
        try await PrestartCopy.copyIn(from: source.file, to: "/", mode: 0o640, createParents: true, rootfs: Self.rootfs, agent: agent)
        // The agent resolves the path confined to the root filesystem: the root goes with the
        // request, and the path is the container's, never the VM's.
        #expect(await agent.copies == [.init(isDirectory: false, root: Self.rootfs, path: "/hello.txt", mode: 0o640, createParents: true)])
        #expect(await agent.identityRoots == [Self.rootfs])
    }

    @Test("a directory goes as an archive; a missing destination is the path itself")
    func directoryAndMissing() async throws {
        let source = try Source()
        let agent = FakeAgent(["/srv": Self.directory])
        try await PrestartCopy.copyIn(from: source.directory, to: "/srv", mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        try await PrestartCopy.copyIn(from: source.file, to: "/etc/app/config", mode: 0o644, createParents: true, rootfs: Self.rootfs, agent: agent)
        #expect(
            await agent.copies == [
                .init(isDirectory: true, root: Self.rootfs, path: "/srv/smoke", mode: 0, createParents: true),
                .init(isDirectory: false, root: Self.rootfs, path: "/etc/app/config", mode: 0o644, createParents: true),
            ])
    }

    @Test("an existing file is written over; a directory over a file is refused")
    func existingFile() async throws {
        let source = try Source()
        let agent = FakeAgent(["/etc/motd": Self.file])
        try await PrestartCopy.copyIn(from: source.file, to: "/etc/motd", mode: 0o644, createParents: false, rootfs: Self.rootfs, agent: agent)
        #expect(await agent.copies.map(\.path) == ["/etc/motd"])
        await #expect {
            try await PrestartCopy.copyIn(from: source.directory, to: "/etc/motd", mode: 0, createParents: false, rootfs: Self.rootfs, agent: agent)
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("cannot copy directory over existing file") == true
        }
        #expect(await agent.copies.count == 1)
    }

    @Test("a destination that climbs with '..' or is relative is refused before anything is asked")
    func climbingRefused() async throws {
        let source = try Source()
        let agent = FakeAgent(["/": Self.directory, "/tmp": Self.directory])
        for destination in ["/tmp/../../etc", "/..", "tmp"] {
            await #expect(throws: ContainerizationError.self) {
                try await PrestartCopy.copyIn(from: source.file, to: destination, mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
            }
        }
        #expect(await agent.copies.isEmpty)
        #expect(await agent.identityRoots.isEmpty)
        // Control: the same place spelled without climbing is copied to.
        try await PrestartCopy.copyIn(from: source.file, to: "/tmp/./", mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        #expect(await agent.copies.map(\.path) == ["/tmp/hello.txt"])
    }

    @Test("a parent that is a symlink out of the image is never written through: the path stays the container's, resolved in its root")
    func symlinkedParent() async throws {
        let source = try Source()
        // `/data` is a symlink to `/` in the VM, say. Confined to the root filesystem it is
        // whatever it names there; the copy asks the agent to resolve it in the root, not in
        // the VM, so the write cannot leave the root filesystem.
        let agent = FakeAgent(["/data": Self.directory])
        try await PrestartCopy.copyIn(from: source.file, to: "/data", mode: 0o644, createParents: true, rootfs: Self.rootfs, agent: agent)
        let copy = try #require(await agent.copies.first)
        #expect(copy.root == Self.rootfs)
        #expect(copy.path == "/data/hello.txt")
        #expect(!copy.path.hasPrefix("/run/container"))
    }

    @Test("a missing source is refused")
    func missingSource() async throws {
        let agent = FakeAgent(["/": Self.directory])
        await #expect(throws: ContainerizationError.self) {
            try await PrestartCopy.copyIn(
                from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), to: "/", mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.copies.isEmpty)
    }

    @Test("the copy's vsock ports are taken in turn from a range apart from containerization's")
    func ports() {
        let first = VminitdCopyAgent.port()
        let second = VminitdCopyAgent.port()
        #expect(first >= VminitdCopyAgent.portBase && second >= VminitdCopyAgent.portBase)
        #expect(first != second)
        // containerization's own allocator counts up from 0x1000_0000, one container at a time.
        #expect(VminitdCopyAgent.portBase > 0x1000_0000 + 0x10_0000)
    }
}
