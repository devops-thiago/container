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
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import ContainerRuntimeLinuxServer

/// A dev container whose Compose file binds the host's Docker socket at /var/run/docker.sock,
/// with the docker-outside-of-docker feature binding it again at /var/run/docker-host.sock, in
/// an image where the first is a symbolic link to the second.
struct StackedSocketBindsTests {
    static let socket = "/Users/me/Library/Group Containers/group.example/run/docker.sock"
    static let mounts: [Filesystem] = [
        .virtiofs(source: "/Users/me/src", destination: "/workspaces", options: []),
        .virtiofs(source: socket, destination: "/var/run/docker.sock", options: []),
        .virtiofs(source: socket, destination: "/var/run/docker-host.sock", options: []),
    ]

    private static func isSocket(_ mount: Filesystem) -> Bool { mount.source.hasSuffix(".sock") }

    @Test("a second bind of one socket onto the same file is left out; binds onto different files are kept")
    func redundant() {
        // Linked: both destinations are file 7.
        let linked = StackedSocketBinds.redundant(in: Self.mounts, isSocket: Self.isSocket) { path in
            ["/var/run/docker.sock": 7, "/var/run/docker-host.sock": 7][path]
        }
        #expect(linked == [2])
        // Control: two files, as in an image without the feature, keep both.
        let apart = StackedSocketBinds.redundant(in: Self.mounts, isSocket: Self.isSocket) { path in
            ["/var/run/docker.sock": 7, "/var/run/docker-host.sock": 8][path]
        }
        #expect(apart.isEmpty)
        // Nothing there yet: nothing to tell, so nothing is left out.
        let nowhere: (String) -> Int? = { _ in nil }
        #expect(StackedSocketBinds.redundant(in: Self.mounts, isSocket: Self.isSocket, file: nowhere).isEmpty)
        // Different sockets onto one file are left as they are.
        var other = Self.mounts
        other[2].source = "/tmp/other.sock"
        #expect(StackedSocketBinds.redundant(in: other, isSocket: Self.isSocket) { _ in 7 }.isEmpty)
    }

    @Test("the files are read from the root filesystem image, through its symbolic links")
    func readsTheImage() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ssb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func image(_ name: String, link: Bool) throws -> String {
            let path = directory.appending(path: name).path
            let formatter = try EXT4.Formatter(FilePath(path), blockSize: 4096, minDiskSize: 16 * 1024 * 1024)
            try formatter.create(path: FilePath("/var/run"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            try formatter.create(path: FilePath("/var/run/docker-host.sock"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644))
            if link {
                try formatter.create(
                    path: FilePath("/var/run/docker.sock"), link: FilePath("/var/run/docker-host.sock"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
            }
            try formatter.close()
            return path
        }
        let linked = StackedSocketBinds.removing(from: Self.mounts, rootfs: try image("linked.ext4", link: true), isSocket: Self.isSocket)
        #expect(linked.map(\.destination) == ["/workspaces", "/var/run/docker.sock"])
        let plain = StackedSocketBinds.removing(from: Self.mounts, rootfs: try image("plain.ext4", link: false), isSocket: Self.isSocket)
        #expect(plain.map(\.destination) == Self.mounts.map(\.destination))
    }
}
