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

import ContainerizationEXT4
import Foundation
import SystemPackage

/// What an ext4 disk image's superblock says about the space its files hold, read from the
/// host without mounting it.
///
/// The counts are what the kernel last wrote back. A mounted filesystem keeps its own in
/// memory, so they are only right for one that was unmounted cleanly: `isClean` says so.
struct EXT4SuperblockUsage: Equatable {
    static let offset: UInt64 = 1024
    static let length = 1024
    static let magic: UInt16 = 0xEF53
    /// `s_state`'s "cleanly unmounted" bit, which the kernel clears on disk while a filesystem
    /// without a journal is mounted.
    static let validState: UInt16 = 0x1
    /// `INCOMPAT_RECOVER`: the journal has to be replayed, which is so on disk while a
    /// journaled filesystem is mounted and after it was not unmounted cleanly.
    static let needsRecovery: UInt32 = 0x4

    let blockSize: UInt64
    let blockCount: UInt64
    let usedBlocks: UInt64
    let isClean: Bool

    var usedBytes: UInt64 { usedBlocks * blockSize }

    /// Reads the superblock of the image at `url`. Nil when it is not ext4.
    static func read(_ url: URL) throws -> EXT4SuperblockUsage? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: length), data.count == length else { return nil }
        return parse(data)
    }

    /// The fields this type reads, from the 1024 bytes of a superblock.
    static func parse(_ data: Data) -> EXT4SuperblockUsage? {
        guard data.count >= length else { return nil }
        let bytes = [UInt8](data.prefix(length))
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        guard u16(0x38) == magic else { return nil }
        let logBlockSize = u32(0x18)
        guard logBlockSize <= 6 else { return nil }
        let incompat = u32(0x60)
        // 64-bit block counts only count when the filesystem says it uses them.
        let wide = incompat & 0x80 != 0
        let blocks = UInt64(u32(0x04)) | (wide ? UInt64(u32(0x150)) << 32 : 0)
        let free = UInt64(u32(0x0C)) | (wide ? UInt64(u32(0x158)) << 32 : 0)
        guard free <= blocks else { return nil }
        return EXT4SuperblockUsage(
            blockSize: UInt64(1024) << logBlockSize, blockCount: blocks, usedBlocks: blocks - free,
            isClean: u16(0x3A) & validState != 0 && incompat & needsRecovery == 0)
    }
}

/// A container's writable size: what its root filesystem holds beyond the image's, as dockerd
/// reports `SizeRw`.
///
/// A container's root filesystem is a copy-on-write clone of its image's unpacked snapshot, so
/// the blocks it uses beyond the snapshot's are what the container wrote. That is the
/// containerd image store's measure (the blocks of the writable layer), and stays below it:
/// a file changed in place adds only the blocks that grew, where a layer copies the file up.
///
/// The engine writes `/etc/hostname`, `/etc/hosts` and `/etc/resolv.conf` into the root
/// filesystem at every start, making `/etc` when the image has none; dockerd keeps them out of
/// the writable layer. Up to a block each is not counted, so a container that wrote nothing
/// shows nothing.
enum ContainerWritableSize {
    static let engineFileBlocks: UInt64 = 4

    /// The size, or nil when it cannot be told without a figure larger than dockerd's: a
    /// filesystem that is mounted or was not unmounted cleanly, or whose snapshot is gone.
    static func measure(rootfs: URL, snapshot: URL) throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: rootfs.path(percentEncoded: false)) else {
            // The engine clones the snapshot at the first start: a container that never ran
            // has written nothing.
            return 0
        }
        guard FileManager.default.fileExists(atPath: snapshot.path(percentEncoded: false)),
            let base = try EXT4SuperblockUsage.read(snapshot),
            let current = try EXT4SuperblockUsage.read(rootfs)
        else { return nil }
        return delta(current: current, base: base)
    }

    static func delta(current: EXT4SuperblockUsage, base: EXT4SuperblockUsage) -> UInt64? {
        guard current.isClean, base.isClean, current.blockSize == base.blockSize, current.blockCount == base.blockCount else {
            return nil
        }
        guard current.usedBlocks > base.usedBlocks + engineFileBlocks else { return 0 }
        return (current.usedBlocks - base.usedBlocks - engineFileBlocks) * current.blockSize
    }
}

/// A volume's size as dockerd reports it for a local volume: the bytes of every file in it, a
/// file with several links once, directories not counted.
enum VolumeDataSize {
    static let typeMask: UInt16 = 0xF000
    static let directoryType: UInt16 = 0x4000

    /// The size, or nil when the volume is mounted (its on-disk metadata is not current then)
    /// or cannot be read.
    static func measure(image: URL) throws -> UInt64? {
        guard let superblock = try EXT4SuperblockUsage.read(image), superblock.isClean else { return nil }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path(percentEncoded: false)))
        var seen = Set<EXT4.InodeNumber>()
        var total: UInt64 = 0
        var directories = [FilePath("/")]
        while let directory = directories.popLast() {
            for name in try reader.listDirectory(directory) {
                let path = directory.appending(name)
                let (number, inode) = try reader.stat(path, followSymlinks: false)
                if inode.mode & typeMask == directoryType {
                    directories.append(path)
                    continue
                }
                let size = UInt64(inode.sizeHigh) << 32 | UInt64(inode.sizeLow)
                guard size > 0, seen.insert(number).inserted else { continue }
                total += size
            }
        }
        return total
    }
}
