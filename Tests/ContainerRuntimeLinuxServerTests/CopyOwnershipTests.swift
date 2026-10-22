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
import ContainerizationArchive
import Darwin
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

struct CopyOwnershipTests {
    /// The image dockerd's own test builds: `testuser` 2375 in `testgroup` 2376.
    static let passwd = """
        root:x:0:0:root:/root:/bin/sh
        # a comment
        testuser:x:2375:2376::/home/testuser:/bin/sh
        """
    static let group = """
        root:x:0:
        testgroup:x:2376:testuser
        """

    @Test(
        "copyUIDGID resolves the container's user as dockerd does",
        arguments: [
            ("testuser:testgroup", "2375:2376"),
            ("testuser", "2375:2376"),
            ("2375", "2375:2376"),
            ("7777", "7777:0"),
            ("7777:", "7777:0"),
            (":7777", "0:7777"),
            ("2375:2376", "2375:2376"),
            ("testuser:7777", "2375:7777"),
            ("7777:testgroup", "7777:2376"),
            ("root", "0:0"),
        ])
    func containerUser(user: String, expected: String) throws {
        let owner = try CopyUser.owner(of: .raw(userString: user), passwd: Self.passwd, group: Self.group)
        #expect(owner?.description == expected)
    }

    @Test("a container without a user leaves each file its source's owner")
    func noUser() throws {
        #expect(try CopyUser.owner(of: .id(uid: 0, gid: 0), passwd: Self.passwd, group: Self.group) == nil)
        #expect(try CopyUser.owner(of: .raw(userString: ""), passwd: Self.passwd, group: Self.group) == nil)
        #expect(!CopyUser.needsLookup(.id(uid: 0, gid: 0)))
        #expect(try CopyUser.owner(of: .id(uid: 1000, gid: 1001), passwd: nil, group: nil) == CopyOwner(uid: 1000, gid: 1001))
    }

    @Test("a name the container does not know is refused, as dockerd refuses it")
    func unknownNames() {
        #expect(throws: (any Error).self) { try CopyUser.owner(of: .raw(userString: "nobody"), passwd: Self.passwd, group: Self.group) }
        #expect(throws: (any Error).self) { try CopyUser.owner(of: .raw(userString: "testuser:nogroup"), passwd: Self.passwd, group: Self.group) }
        #expect(throws: (any Error).self) { try CopyUser.owner(of: .raw(userString: "testuser"), passwd: nil, group: nil) }
    }

    /// The owner of each entry of the archive `CopyArchive` makes of `source`, by path.
    static func owners(_ source: URL, isDirectory: Bool, owner: CopyOwner?) throws -> [String: String] {
        let archive = source.deletingLastPathComponent().appending(path: "owners-\(UUID().uuidString).tar.gz")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        try CopyArchive.write(source, isDirectory: isDirectory, name: "file", mode: 0o644, owner: owner, to: handle.fileDescriptor)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: archive) }
        var owners: [String: String] = [:]
        for (entry, _) in try ArchiveReader(format: .pax, filter: .gzip, file: archive) {
            // A directory's name may carry a trailing `/`; the root is `./` either way.
            var name = entry.path ?? ""
            if name != "./", name.hasSuffix("/") { name.removeLast() }
            owners[name] = "\(entry.owner.map(String.init) ?? "-"):\(entry.group.map(String.init) ?? "-")"
        }
        return owners
    }

    @Test("an archive names each file's host owner, or the owner recorded when it was staged")
    func recordedOwners() throws {
        let source = try PrestartCopyTests.Source()
        let nested = source.directory.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let inner = nested.appending(path: "inner.txt")
        try Data("inner\n".utf8).write(to: inner)
        try Data("plain\n".utf8).write(to: source.directory.appending(path: "plain.txt"))
        try CopyOwner.record(CopyOwner(uid: 1234, gid: 4321), at: inner.path)
        try CopyOwner.record(CopyOwner(uid: 0, gid: 0), at: nested.path)
        var info = stat()
        #expect(lstat(source.directory.path, &info) == 0)
        let host = "\(info.st_uid):\(info.st_gid)"

        let owners = try Self.owners(source.directory, isDirectory: true, owner: nil)
        #expect(owners["./"] == host)
        #expect(owners["plain.txt"] == host)
        #expect(owners["nested"] == "0:0")
        #expect(owners["nested/inner.txt"] == "1234:4321")

        try CopyOwner.record(CopyOwner(uid: 7, gid: 8), at: source.file.path)
        #expect(try Self.owners(source.file, isDirectory: false, owner: nil) == ["file": "7:8"])
    }

    @Test("copyUIDGID's owner owns every entry, whatever was recorded")
    func overrideOwner() throws {
        let source = try PrestartCopyTests.Source()
        let inner = source.directory.appending(path: "inner.txt")
        try Data("inner\n".utf8).write(to: inner)
        try CopyOwner.record(CopyOwner(uid: 1234, gid: 4321), at: inner.path)
        let owner = CopyOwner(uid: 405, gid: 100)
        #expect(try Self.owners(source.directory, isDirectory: true, owner: owner) == ["./": "405:100", "inner.txt": "405:100"])
        #expect(try Self.owners(source.file, isDirectory: false, owner: owner) == ["file": "405:100"])
    }

    @Test("a recorded owner reads back, and a file without one has none")
    func recordRoundTrip() throws {
        let source = try PrestartCopyTests.Source()
        #expect(CopyOwner.recorded(at: source.file.path) == nil)
        try CopyOwner.record(CopyOwner(uid: 65534, gid: 65533), at: source.file.path)
        #expect(CopyOwner.recorded(at: source.file.path) == CopyOwner(uid: 65534, gid: 65533))
    }
}
