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
import ContainerizationEXT4
import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerRuntimeLinuxServer

/// What a start binds, for a container whose configuration was saved before binds of the host's
/// Docker socket were the engine's; and the reads of the root filesystem image behind it.
struct StartMountsTests {
    static let engine = "/Users/me/Library/Group Containers/group.example/run/docker.sock"

    /// A saved configuration's mounts, the host's Docker socket still by its own path.
    static let saved: [Filesystem] = [
        .virtiofs(source: "/Users/me/src", destination: "/workspaces", options: []),
        .virtiofs(source: "/var/run/docker.sock", destination: "/var/run/docker.sock", options: []),
    ]

    @Test("a start binds the engine's socket for the host's in a saved configuration")
    func mapsSavedConfiguration() async throws {
        let mounts = try await RuntimeService.mountsToBind(Self.saved, rootfs: "/nonexistent", enginePath: Self.engine, answers: { $0 == Self.engine }) {
            _ in false
        }
        #expect(mounts.map(\.source) == ["/Users/me/src", Self.engine])
    }

    @Test("a start refuses the bind, naming the setting, when nothing answers on the engine's socket")
    func refusesWhenNotServed() async throws {
        await #expect {
            _ = try await RuntimeService.mountsToBind(Self.saved, rootfs: "/nonexistent", enginePath: Self.engine, answers: { _ in false }) { _ in false }
        } throws: { error in
            (error as? ContainerizationError)?.message == DockerHostSocket.notServedMessage
        }
        // A container that binds no Docker socket starts whatever answers.
        let plain = try await RuntimeService.mountsToBind(
            [Self.saved[0]], rootfs: "/nonexistent", enginePath: Self.engine,
            answers: { _ in
                Issue.record("nothing to ask")
                return false
            }
        ) { _ in false }
        #expect(plain.map(\.source) == ["/Users/me/src"])
    }

    @Test("statistics carry the container's name, not the ID the guest knows a long-named one by")
    func statisticsCarryTheName() {
        let name = "6038_desenvolvimento_backend_com_ia_essencial_java_devcontainer-app-1"
        let stats = ContainerStatistics(id: RuntimeService.guestContainerID(for: name))
        #expect(stats.id != name)
        #expect(RuntimeService.containerStats(stats, id: name).id == name)
    }

    @Test("files are found through absolute and relative links, in nested and crowded folders")
    func rootfsFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "rf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "rootfs.ext4").path
        let formatter = try EXT4.Formatter(FilePath(path), blockSize: 4096, minDiskSize: 64 * 1024 * 1024)
        try formatter.create(path: FilePath("/run"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/var"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        try formatter.create(path: FilePath("/var/run"), link: FilePath("../run"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        try formatter.create(path: FilePath("/run/docker-host.sock"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644))
        try formatter.create(path: FilePath("/run/docker.sock"), link: FilePath("/var/run/docker-host.sock"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        // A long link target, stored in a block of its own.
        let deep = "/" + (0..<12).map { "level-\($0)-with-a-long-enough-name" }.joined(separator: "/")
        var built = ""
        for component in deep.split(separator: "/") {
            built += "/\(component)"
            try formatter.create(path: FilePath(built), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        }
        try formatter.create(path: FilePath("\(deep)/file"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644))
        try formatter.create(path: FilePath("/far"), link: FilePath("\(deep)/file"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        // A folder with more entries than one block holds.
        try formatter.create(path: FilePath("/crowded"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        for index in 0..<400 {
            try formatter.create(path: FilePath("/crowded/entry-with-a-long-name-\(index)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644))
        }
        try formatter.close()

        let files = try RootfsFiles(image: path)
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(path))
        #expect(try files.file("/var/run/docker.sock") == files.file("/run/docker-host.sock"))
        #expect(try files.file("/run/docker.sock") == reader.stat(FilePath("/run/docker-host.sock")).inodeNumber)
        #expect(try files.file("/far") == reader.stat(FilePath("\(deep)/file")).inodeNumber)
        #expect(try files.file("/crowded/entry-with-a-long-name-399") == reader.stat(FilePath("/crowded/entry-with-a-long-name-399")).inodeNumber)
        #expect(throws: RootfsFiles.Failure.self) { try files.file("/run/missing.sock") }
        #expect(throws: RootfsFiles.Failure.self) { try files.file("/run/docker-host.sock/inside") }
    }
}
