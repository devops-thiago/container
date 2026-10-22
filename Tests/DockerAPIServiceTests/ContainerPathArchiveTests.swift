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
import Foundation
import Testing

@testable import DockerAPIService

/// `ContainerPathArchive`, which `container cp CTR:SRC -` and `container cp - CTR:DEST` stream
/// through: the entries `docker cp` would write and take.
@Suite(.timeLimit(.minutes(1)))
struct ContainerPathArchiveTests {
    final class Setup {
        let tools: FakeTools
        let container: ContainerSnapshot
        let out: URL

        init() throws {
            tools = try FakeTools(snapshots: ToolHarness.snapshots())
            container = try #require(ToolHarness.snapshots().first)
            out = tools.scratch.deletingLastPathComponent().appending(path: "out-\(UUID().uuidString).tar")
            let fm = FileManager.default
            try fm.createDirectory(at: tools.root.appending(path: "data/sub"), withIntermediateDirectories: true)
            try Data("hi\n".utf8).write(to: tools.root.appending(path: "data/a.txt"))
            try Data("deep\n".utf8).write(to: tools.root.appending(path: "data/sub/b.txt"))
            try fm.createSymbolicLink(atPath: tools.root.appending(path: "data/link").path, withDestinationPath: "a.txt")
            try fm.createSymbolicLink(atPath: tools.root.appending(path: "dlink").path, withDestinationPath: "/data")
            try Data("x\n".utf8).write(to: tools.root.appending(path: "file"))
        }

        deinit { tools.cleanup() }

        /// What `write` streams for `path`: each entry's name and type flag, in order.
        func archive(_ path: String, followLink: Bool = false) async throws -> [String] {
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try await ContainerPathArchive.write(
                tools, container: container, path: path, reference: "box", followLink: followLink, requester: nil, to: handle)
            try handle.close()
            return try Self.entries(Array(Data(contentsOf: out)))
        }

        /// Feeds `bytes` to `extract` as stdin would.
        func extract(_ bytes: [UInt8], into path: String) async throws {
            let input = tools.scratch.deletingLastPathComponent().appending(path: "in-\(UUID().uuidString).tar")
            try Data(bytes).write(to: input)
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            try await ContainerPathArchive.extract(tools, container: container, from: handle, into: path, reference: "box", requester: nil)
        }

        static func entries(_ bytes: [UInt8]) throws -> [String] {
            var names: [String] = []
            var offset = 0
            while offset + DockerTar.blockSize <= bytes.count {
                let block = Array(bytes[offset..<offset + DockerTar.blockSize])
                if block.allSatisfy({ $0 == 0 }) { break }
                let size = try DockerTarExtractor.number(block[124..<136])
                let type = block[156] == 0x32 ? " -> " + DockerTarExtractor.string(block[157..<257]) : ""
                names.append(DockerTarExtractor.ustarName(block) + type)
                offset += DockerTar.blockSize * (1 + Int((size + 511) / 512))
            }
            return names
        }
    }

    @Test("a file is one entry named for its last component")
    func file() async throws {
        let setup = try Setup()
        #expect(try await setup.archive("/data/a.txt") == ["a.txt"])
    }

    @Test("a directory, with or without a trailing slash, is its name and everything under it; `/.` names it `.`")
    func directory() async throws {
        let setup = try Setup()
        let expected = ["data/", "data/a.txt", "data/link -> a.txt", "data/sub/", "data/sub/b.txt"]
        #expect(try await setup.archive("/data") == expected)
        #expect(try await setup.archive("/data/") == expected)
        #expect(try await setup.archive("/data/.") == ["./", "./a.txt", "./link -> a.txt", "./sub/", "./sub/b.txt"])
    }

    @Test("a symlink is archived as the link; -L archives what it points to under the target's name")
    func symlinks() async throws {
        let setup = try Setup()
        #expect(try await setup.archive("/data/link") == ["link -> a.txt"])
        #expect(try await setup.archive("/dlink") == ["dlink -> /data"])
        #expect(try await setup.archive("/data/link", followLink: true) == ["a.txt"])
        #expect(try await setup.archive("/dlink", followLink: true).first == "data/")
    }

    @Test("a path the container does not have is dockerd's not found")
    func missing() async throws {
        let setup = try Setup()
        await #expect(throws: DockerAPIError.notFound("Could not find the file /nope in container box")) {
            _ = try await setup.archive("/nope")
        }
    }

    @Test("a tar on stdin is copied into the directory, each top-level name with its mode")
    func extractIntoDirectory() async throws {
        let setup = try Setup()
        var tar = TarBuilder()
        tar.directory("dir")
        tar.file("dir/inner.txt", "inner")
        tar.file("f.txt", "f", mode: 0o600)
        try await setup.extract(tar.archive, into: "/data")
        #expect(setup.tools.copyCalls.filter { $0.hasPrefix("in ") } == ["in dir /data 755", "in f.txt /data 600"])
        #expect(try String(contentsOf: setup.tools.root.appending(path: "data/dir/inner.txt"), encoding: .utf8) == "inner")
    }

    @Test("a destination that is missing or not a directory is refused in the Docker CLI's words, before anything is copied")
    func extractRefusesNonDirectory() async throws {
        let setup = try Setup()
        var tar = TarBuilder()
        tar.file("f.txt", "f")
        for path in ["/nope/", "/file"] {
            await #expect(throws: DockerAPIError.badRequest("destination \"box:\(path)\" must be a directory")) {
                try await setup.extract(tar.archive, into: path)
            }
        }
        #expect(setup.tools.copyCalls.filter { $0.hasPrefix("in ") }.isEmpty)
    }

    @Test("a destination that is a link to a directory is copied into where it points")
    func extractThroughLink() async throws {
        let setup = try Setup()
        var tar = TarBuilder()
        tar.file("f.txt", "f")
        try await setup.extract(tar.archive, into: "/dlink")
        #expect(setup.tools.copyCalls.last == "in f.txt /data 644")
    }

    @Test("an empty stdin copies nothing and succeeds, as docker cp does")
    func extractEmpty() async throws {
        let setup = try Setup()
        try await setup.extract([], into: "/data")
        #expect(setup.tools.copyCalls.filter { $0.hasPrefix("in ") }.isEmpty)
    }

    @Test("names: the last component, `.` for the root and a trailing `/.`")
    func entryNames() {
        #expect(ContainerPathArchive.entryName(for: "/etc/hostname") == "hostname")
        #expect(ContainerPathArchive.entryName(for: "/etc/") == "etc")
        #expect(ContainerPathArchive.entryName(for: "/etc/.") == ".")
        #expect(ContainerPathArchive.entryName(for: "/") == ".")
    }

    @Test("a link resolves from its directory and keeps a trailing `/` or `/.`, as moby's GetRebaseName")
    func resolve() {
        #expect(ContainerPathArchive.resolve("/data/link", linkTarget: "a.txt") == "/data/a.txt")
        #expect(ContainerPathArchive.resolve("/dlink", linkTarget: "/data") == "/data")
        #expect(ContainerPathArchive.resolve("/a/b/link", linkTarget: "../c//d/./") == "/a/c/d")
        #expect(ContainerPathArchive.resolve("/x/link/.", linkTarget: "/data") == "/data/.")
        #expect(ContainerPathArchive.resolve("/x/link/", linkTarget: "/data") == "/data/")
        #expect(ContainerPathArchive.resolve("/x/link/.", linkTarget: "y") == "/x/y/.")
    }
}
