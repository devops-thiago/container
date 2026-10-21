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

import Foundation

/// The files paths name in an ext4 root filesystem image, read lazily: only the directories on
/// each path, never the whole tree. Containerization's reader walks every directory when it
/// opens an image, seconds and hundreds of megabytes on a large one, to answer a few lookups.
///
/// It reads what the engine's formatter writes: extent-mapped files and directories, linear
/// directory entries (a hashed directory's leaves are linear too), fast and slow symbolic links.
/// Anything else is reported as not found, which callers take as "cannot tell".
final class RootfsFiles {
    enum Failure: Error { case unreadable, unsupported, notFound, loop }

    private let handle: FileHandle
    private let blockSize: UInt64
    private let inodesPerGroup: UInt32
    private let inodeSize: UInt64
    private let descriptorSize: UInt64
    private let descriptorTable: UInt64
    private let is64Bit: Bool

    private static let rootInode: UInt32 = 2

    init(image path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.unreadable }
        self.handle = handle
        let superblock = try Self.read(handle, at: 1024, count: 1024)
        guard superblock.u16(56) == 0xEF53 else { throw Failure.unsupported }
        blockSize = 1024 << UInt64(superblock.u32(24))
        inodesPerGroup = superblock.u32(40)
        inodeSize = UInt64(superblock.u16(88))
        is64Bit = superblock.u32(96) & 0x80 != 0
        descriptorSize = is64Bit ? UInt64(max(superblock.u16(254), 32)) : 32
        descriptorTable = (UInt64(superblock.u32(20)) + 1) * blockSize
        guard inodesPerGroup > 0, inodeSize >= 128 else { throw Failure.unsupported }
    }

    deinit { try? handle.close() }

    /// The inode number of the file `path` names, following symbolic links throughout.
    func file(_ path: String) throws -> UInt32 {
        var pending = path.split(separator: "/").map(String.init)
        var stack: [UInt32] = []
        var current = Self.rootInode
        var hops = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." || name.isEmpty { continue }
            if name == ".." {
                current = stack.popLast() ?? Self.rootInode
                continue
            }
            let directory = try inode(current)
            guard directory.mode & 0xF000 == 0x4000 else { throw Failure.notFound }
            guard let child = try entry(named: name, in: directory) else { throw Failure.notFound }
            let node = try inode(child)
            if node.mode & 0xF000 == 0xA000 {
                hops += 1
                guard hops <= 40 else { throw Failure.loop }
                let target = try linkTarget(node)
                if target.hasPrefix("/") {
                    stack = []
                    current = Self.rootInode
                }
                pending = target.split(separator: "/").map(String.init) + pending
                continue
            }
            stack.append(current)
            current = child
        }
        return current
    }

    // MARK: Reading

    private struct Inode {
        let mode: UInt16
        let size: UInt64
        let flags: UInt32
        let block: Data
    }

    private func inode(_ number: UInt32) throws -> Inode {
        guard number > 0 else { throw Failure.notFound }
        let group = UInt64((number - 1) / inodesPerGroup)
        let index = UInt64((number - 1) % inodesPerGroup)
        let descriptor = try Self.read(handle, at: descriptorTable + group * descriptorSize, count: Int(descriptorSize))
        var table = UInt64(descriptor.u32(8))
        if is64Bit && descriptorSize >= 64 { table |= UInt64(descriptor.u32(0x28)) << 32 }
        let raw = try Self.read(handle, at: table * blockSize + index * inodeSize, count: 128)
        let size = UInt64(raw.u32(4)) | UInt64(raw.u32(0x6C)) << 32
        return Inode(mode: raw.u16(0), size: size, flags: raw.u32(0x20), block: raw.subdata(in: 0x28..<0x64))
    }

    /// The physical blocks holding the first `count` logical blocks of a file, in order.
    private func blocks(_ node: Inode) throws -> [UInt64] {
        guard node.flags & 0x80000 != 0 else { throw Failure.unsupported }
        let count = (node.size + blockSize - 1) / blockSize
        var result: [UInt64] = []
        try collect(node.block, into: &result)
        return Array(result.prefix(Int(count)))
    }

    private func collect(_ node: Data, into result: inout [UInt64]) throws {
        guard node.u16(0) == 0xF30A else { throw Failure.unsupported }
        let entries = Int(node.u16(2))
        let depth = node.u16(6)
        for index in 0..<entries {
            let offset = 12 + index * 12
            if depth == 0 {
                let length = UInt64(node.u16(offset + 4) & 0x7FFF)
                let start = UInt64(node.u16(offset + 6)) << 32 | UInt64(node.u32(offset + 8))
                result.append(contentsOf: (0..<length).map { start + $0 })
            } else {
                let leaf = UInt64(node.u16(offset + 8)) << 32 | UInt64(node.u32(offset + 4))
                try collect(try Self.read(handle, at: leaf * blockSize, count: Int(blockSize)), into: &result)
            }
        }
    }

    private func entry(named name: String, in directory: Inode) throws -> UInt32? {
        let wanted = Array(name.utf8)
        for block in try blocks(directory) {
            let data = try Self.read(handle, at: block * blockSize, count: Int(blockSize))
            var offset = 0
            while offset + 8 <= data.count {
                let number = data.u32(offset)
                let length = Int(data.u16(offset + 4))
                let nameLength = Int(data[data.startIndex + offset + 6])
                guard length >= 8 else { break }
                if number != 0, offset + 8 + nameLength <= data.count,
                    Array(data[(data.startIndex + offset + 8)..<(data.startIndex + offset + 8 + nameLength)]) == wanted
                {
                    return number
                }
                offset += length
            }
        }
        return nil
    }

    private func linkTarget(_ node: Inode) throws -> String {
        let bytes: Data
        if node.flags & 0x80000 == 0 && node.size < 60 {
            bytes = node.block.prefix(Int(node.size))
        } else {
            var collected = Data()
            for block in try blocks(node) {
                collected.append(try Self.read(handle, at: block * blockSize, count: Int(blockSize)))
            }
            bytes = collected.prefix(Int(node.size))
        }
        guard let target = String(data: bytes, encoding: .utf8) else { throw Failure.unsupported }
        return target
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.unreadable }
        return data
    }
}

extension Data {
    fileprivate func u16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    fileprivate func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
