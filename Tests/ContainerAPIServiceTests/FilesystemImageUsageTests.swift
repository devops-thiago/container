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
import ContainerRuntimeClient
import Containerization
import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIService

/// The sizes `docker system df`, `docker ps --size` and a volume prune report, read from the
/// ext4 disk images the engine keeps.
struct FilesystemImageUsageTests {
    private final class Scratch {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("fs-usage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
    }

    private static let size: UInt64 = 64 * 1024 * 1024

    /// An image the engine's formatter makes, with `files` (path to bytes) and `build` run on
    /// the formatter before it closes.
    private static func image(at url: URL, files: [String: Int] = [:], build: (EXT4.Formatter) throws -> Void = { _ in }) throws {
        let formatter = try EXT4.Formatter(FilePath(url.path), blockSize: 4096, minDiskSize: size)
        try formatter.unlink(path: FilePath("/lost+found"))
        for (path, count) in files.sorted(by: { $0.key < $1.key }) {
            let stream = InputStream(data: Data(repeating: 0x5A, count: count))
            stream.open()
            defer { stream.close() }
            try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
        }
        try build(formatter)
        try formatter.close()
    }

    /// Overwrites `count` bytes of the superblock at `offset`.
    private static func patch(_ url: URL, at offset: Int, _ bytes: [UInt8]) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: EXT4SuperblockUsage.offset + UInt64(offset))
        try handle.write(contentsOf: Data(bytes))
    }

    // MARK: Superblock

    @Test("a formatted image's superblock gives its block size and the blocks in use, clean")
    func superblock() throws {
        let scratch = try Scratch()
        let empty = scratch.path("empty.img")
        let full = scratch.path("full.img")
        try Self.image(at: empty)
        try Self.image(at: full, files: ["/data": 1 << 20])

        let base = try #require(try EXT4SuperblockUsage.read(empty))
        let written = try #require(try EXT4SuperblockUsage.read(full))
        #expect(base.blockSize == 4096)
        #expect(base.isClean)
        #expect(base.blockCount == written.blockCount)
        // The 1 MiB file takes 256 blocks.
        #expect(written.usedBlocks >= base.usedBlocks + 256)
        #expect(written.usedBlocks <= base.usedBlocks + 258)
    }

    @Test("a mounted or uncleanly stopped filesystem's counts are not trusted")
    func superblockState() throws {
        let scratch = try Scratch()
        let journaled = scratch.path("mounted.img")
        try Self.image(at: journaled)
        // The journal awaits replay, as it does on disk while the kernel has it mounted.
        try Self.patch(journaled, at: 0x60, [0x46, 0x02, 0x00, 0x00])
        #expect(try EXT4SuperblockUsage.read(journaled)?.isClean == false)

        let unjournaled = scratch.path("valid-cleared.img")
        try Self.image(at: unjournaled)
        // Without a journal the kernel clears "cleanly unmounted" while it is mounted.
        try Self.patch(unjournaled, at: 0x3A, [0x00, 0x00])
        #expect(try EXT4SuperblockUsage.read(unjournaled)?.isClean == false)

        // Control: the same images untouched are clean.
        let control = scratch.path("control.img")
        try Self.image(at: control)
        #expect(try EXT4SuperblockUsage.read(control)?.isClean == true)
    }

    @Test("what is not ext4 has no superblock to read")
    func notEXT4() throws {
        let scratch = try Scratch()
        let zeros = scratch.path("zeros.img")
        try Data(count: 4096).write(to: zeros)
        #expect(try EXT4SuperblockUsage.read(zeros) == nil)
        let short = scratch.path("short.img")
        try Data(count: 1500).write(to: short)
        #expect(try EXT4SuperblockUsage.read(short) == nil)
    }

    // MARK: Container writable size

    private static func usage(used: UInt64, clean: Bool = true, blocks: UInt64 = 1_000_000) -> EXT4SuperblockUsage {
        EXT4SuperblockUsage(blockSize: 4096, blockCount: blocks, usedBlocks: used, isClean: clean)
    }

    @Test("a container's writable size is the blocks it uses beyond its snapshot, less the engine's own files")
    func writableDelta() {
        let base = Self.usage(used: 2_373_883)
        // 50 MiB written and a block of metadata, measured on a stopped alpine container.
        let wrote = Self.usage(used: 2_386_684)
        #expect(ContainerWritableSize.delta(current: wrote, base: base) == (12_801 - 4) * 4096)
        // Started and stopped with nothing written: the engine's resolv.conf is all it has.
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 2_373_884), base: base) == 0)
        // Fewer blocks than the snapshot, after files of the image were removed.
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 2_000_000), base: base) == 0)
        // Exactly the allowance is nothing; one more block is a block.
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 2_373_887), base: base) == 0)
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 2_373_888), base: base) == 4096)
    }

    @Test("a writable size is not told from a mounted filesystem or one that is not the snapshot's clone")
    func writableUnknown() {
        let base = Self.usage(used: 1000)
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 5000, clean: false), base: base) == nil)
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 5000), base: Self.usage(used: 1000, clean: false)) == nil)
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 5000, blocks: 2_000_000), base: base) == nil)
        // Control: the same counts, clean and of one geometry, are told.
        #expect(ContainerWritableSize.delta(current: Self.usage(used: 5000), base: base) == (4000 - 4) * 4096)
    }

    @Test("measured from the files: none before the first start, none without the snapshot")
    func writableFromFiles() throws {
        let scratch = try Scratch()
        let snapshot = scratch.path("snapshot")
        let rootfs = scratch.path("rootfs.ext4")
        try Self.image(at: snapshot, files: ["/os-release": 100])

        // No clone yet: a container that never started wrote nothing.
        #expect(try ContainerWritableSize.measure(rootfs: rootfs, snapshot: snapshot) == 0)

        try Self.image(at: rootfs, files: ["/os-release": 100, "/data": 1 << 20])
        let measured = try #require(try ContainerWritableSize.measure(rootfs: rootfs, snapshot: snapshot))
        #expect(measured <= 1 << 20)
        #expect(measured >= (1 << 20) - 4 * 4096)

        // The image's snapshot is gone: there is no base to measure against.
        try FileManager.default.removeItem(at: snapshot)
        #expect(try ContainerWritableSize.measure(rootfs: rootfs, snapshot: snapshot) == nil)
    }

    // MARK: Volume data size

    @Test("a volume's size is its files' bytes, a hard-linked file once, directories not counted")
    func volumeData() throws {
        let scratch = try Scratch()
        let volume = scratch.path("volume.img")
        try Self.image(at: volume, files: ["/one": 1, "/three": 3 << 20]) { formatter in
            try formatter.create(path: FilePath("/d"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
            let stream = InputStream(data: Data(repeating: 1, count: 10))
            stream.open()
            defer { stream.close() }
            try formatter.create(path: FilePath("/d/ten"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
            try formatter.link(link: FilePath("/d/again"), target: FilePath("/three"))
            try formatter.create(path: FilePath("/link"), link: FilePath("d/ten"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777))
        }
        // The symlink counts its target's length, as `lstat` gives it to dockerd.
        #expect(try VolumeDataSize.measure(image: volume) == 1 + (3 << 20) + 10 + UInt64("d/ten".utf8.count))
    }

    @Test("an empty volume is nothing, not its disk image's metadata")
    func volumeEmpty() throws {
        let scratch = try Scratch()
        let volume = scratch.path("volume.img")
        try VolumesService.formatVolumeImage(at: volume.path, sizeInBytes: Self.size)
        #expect(try VolumeDataSize.measure(image: volume) == 0)
        // Control: what the engine reported before, the image's allocation, is not nothing.
        #expect(FileManager.default.allocatedSize(of: scratch.directory) > 0)
    }

    @Test("a mounted volume is not measured")
    func volumeMounted() throws {
        let scratch = try Scratch()
        let volume = scratch.path("volume.img")
        try Self.image(at: volume, files: ["/one": 1])
        #expect(try VolumeDataSize.measure(image: volume) == 1)
        try Self.patch(volume, at: 0x3A, [0x00, 0x00])
        #expect(try VolumeDataSize.measure(image: volume) == nil)
    }

    // MARK: Export source

    private static func writeRuntime(bundle: URL, rootFilesystem: Filesystem?, override: Filesystem? = nil) throws {
        let configuration = RuntimeConfiguration(
            path: bundle, initialFilesystem: .virtiofs(source: "/initfs", destination: "/", options: ["ro"]),
            kernel: Kernel(path: URL(fileURLWithPath: "/kernel"), platform: .linuxArm), containerConfiguration: nil,
            containerRootFilesystem: rootFilesystem, options: override.map { ContainerCreateOptions(autoRemove: false, rootFsOverride: $0) })
        try configuration.writeRuntimeConfiguration()
    }

    @Test("a container never started exports its image's snapshot; one that ran, its own disk")
    func exportSource() throws {
        let scratch = try Scratch()
        let bundle = scratch.path("bundle")
        let rootfs = bundle.appendingPathComponent("rootfs.ext4")
        let snapshot = scratch.path("snapshot")
        try Self.writeRuntime(bundle: bundle, rootFilesystem: .block(format: "ext4", source: snapshot.path, destination: "/", options: []))

        #expect(ContainersService.exportSource(bundle: bundle, rootfs: rootfs) == URL(fileURLWithPath: snapshot.path))
        try Data().write(to: rootfs)
        #expect(ContainersService.exportSource(bundle: bundle, rootfs: rootfs) == rootfs)
    }

    @Test("a root filesystem given at create is not swapped for a snapshot")
    func exportSourceOverride() throws {
        let scratch = try Scratch()
        let bundle = scratch.path("bundle")
        let rootfs = bundle.appendingPathComponent("rootfs.ext4")
        let snapshot = scratch.path("snapshot")
        try Self.writeRuntime(
            bundle: bundle, rootFilesystem: .block(format: "ext4", source: snapshot.path, destination: "/", options: []),
            override: .block(format: "ext4", source: scratch.path("mine").path, destination: "/", options: []))
        #expect(ContainersService.exportSource(bundle: bundle, rootfs: rootfs) == rootfs)
        // Control: no runtime configuration at all leaves the bundle's own disk.
        #expect(ContainersService.exportSource(bundle: scratch.path("none"), rootfs: rootfs) == rootfs)
    }
}
