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

import ContainerAPIClient
import Darwin
import Foundation
import Testing

@testable import ContainerBuild

private final class ContextFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root: URL
    let outside: URL

    init() throws {
        root = base.appendingPathComponent("context")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: root.appendingPathComponent("data.txt"))
        try Data("unrelated".utf8).write(to: outside.appendingPathComponent("data.txt"))
    }

    deinit { try? FileManager.default.removeItem(at: base) }
}

@Suite struct ContextDirectoryTests {
    @Test func selectedDirectoryDoesNotRequireReadingItsParent() throws {
        let fixture = try ContextFixture()
        // A folder grant allows searching ancestors, not listing them. This also
        // exercises that permission boundary without requiring sandbox-exec in CI.
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: fixture.base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.base.path) }
        let parent = Darwin.open(fixture.base.path, O_RDONLY | O_DIRECTORY)
        if parent >= 0 { Darwin.close(parent) }
        try #require(parent < 0, "the fixture must deny parent-directory reads")
        let context = try ContextDirectory(fixture.root)
        #expect(try context.open("data.txt").read(offset: 0, length: 0) == Data("selected".utf8))
    }

    @Test func openedFileSurvivesNameReplacement() throws {
        let fixture = try ContextFixture()
        let context = try ContextDirectory(fixture.root)
        let file = try context.open("data.txt")
        let name = fixture.root.appendingPathComponent("data.txt")
        try FileManager.default.moveItem(at: name, to: fixture.root.appendingPathComponent("saved.txt"))
        try FileManager.default.createSymbolicLink(at: name, withDestinationURL: fixture.outside.appendingPathComponent("data.txt"))
        #expect(file.metadata.st_size == 8)
        #expect(try file.read(offset: 0, length: 0) == Data("selected".utf8))
        #expect(throws: ContextDirectory.Error.self) { try context.open("data.txt") }
    }

    @Test func selectedRootSurvivesReplacement() throws {
        let fixture = try ContextFixture()
        let context = try ContextDirectory(fixture.root)
        try FileManager.default.moveItem(at: fixture.root, to: fixture.base.appendingPathComponent("saved"))
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: fixture.outside)
        #expect(try context.open("data.txt").read(offset: 0, length: 0) == Data("selected".utf8))
    }

    @Test(arguments: [false, true])
    func inContextLinksAndLiteralOutsideLinks(absolute: Bool) throws {
        let fixture = try ContextFixture()
        let fm = FileManager.default
        let links = fixture.root.appendingPathComponent("links")
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        let target = absolute ? fixture.root.appendingPathComponent("data.txt").path : "../data.txt"
        try fm.createSymbolicLink(atPath: links.appendingPathComponent("inside").path, withDestinationPath: target)
        try fm.createSymbolicLink(atPath: fixture.root.appendingPathComponent("alias").path, withDestinationPath: "links")
        try fm.createSymbolicLink(atPath: links.appendingPathComponent("outside").path, withDestinationPath: "../../outside/data.txt")
        let context = try ContextDirectory(fixture.root)
        #expect(try context.open("alias/inside").read(offset: 2, length: 3) == Data("lec".utf8))
        #expect(try context.open("alias/../data.txt").read(offset: 0, length: 0) == Data("selected".utf8))
        #expect(try context.open("alias/outside", followFinalSymlink: false).linkTarget == "../../outside/data.txt")
        #expect(throws: ContextDirectory.Error.self) { try context.open("alias/outside") }
        #expect(try context.open("").isDirectory)
        #expect(try context.open("links/..").isDirectory)
    }

    @Test func rejectsInvalidPathsLoopsAndSpecialFiles() throws {
        let fixture = try ContextFixture()
        let context = try ContextDirectory(fixture.root)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("loop").path, withDestinationPath: "loop")
        #expect(throws: ContextDirectory.Error.self) { try context.open("loop") }
        #expect(throws: ContextDirectory.Error.self) { try context.open("../outside/data.txt") }
        #expect(throws: ContextDirectory.Error.self) { try context.open(fixture.outside.appendingPathComponent("data.txt").path) }
        #expect(throws: ContextDirectory.Error.self) { try context.open("data.txt\0suffix") }
        #expect(throws: ContextDirectory.Error.self) { try context.open(String(repeating: "x", count: Int(PATH_MAX) + 1)) }
        #expect(throws: POSIXError.self) { try context.open("missing") }
        let fifo = fixture.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ContextDirectory.Error.self) { try context.open("fifo") }
    }

    @Test func validatesRangesAndDetectsShrinkingFiles() throws {
        let fixture = try ContextFixture()
        let context = try ContextDirectory(fixture.root)
        let file = try context.open("./data.txt")
        #expect(try file.read(offset: 8, length: 100).isEmpty)
        #expect(try context.open(".").read(offset: 0, length: 0).isEmpty)
        #expect(throws: ContextDirectory.Error.self) { try file.read(offset: 0, length: -1) }
        #expect(throws: ContextDirectory.Error.self) { try file.read(offset: UInt64.max, length: 1) }
        let writer = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("data.txt"))
        defer { try? writer.close() }
        try writer.truncate(atOffset: 2)
        #expect(throws: ContextDirectory.Error.self) { try file.read(offset: 0, length: 8) }
    }

    @Test(arguments: ["tar", "json", "Read", "Info"])
    func realProtocolPreservesOrdinaryFilesAndInternalLinks(mode: String) async throws {
        let fixture = try ContextFixture()
        let dir = fixture.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nested-content".utf8).write(to: dir.appendingPathComponent("child.txt"))
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "data.txt")
        let sync = try BuildFSSync(fixture.root)
        let (stream, continuation) = AsyncStream<ClientStream>.makeStream()
        var packet = BuildTransfer()
        packet.id = mode
        packet.source = "link"
        packet.metadata = ["mode": mode, "followpaths": "*"]
        if mode == "Read" {
            try await sync.read(continuation, packet, "test")
        } else if mode == "Info" {
            try await sync.info(continuation, packet, "test")
        } else {
            try await sync.walk(continuation, packet, "test")
        }
        continuation.finish()
        var bytes = Data()
        var responses: [BuildTransfer] = []
        for await event in stream {
            bytes.append(event.buildTransfer.data)
            responses.append(event.buildTransfer)
        }
        if mode == "Read" {
            #expect(bytes == Data("selected".utf8))
            #expect(responses.first?.metadata["size"] == "8")
        } else if mode == "Info" {
            #expect(responses.first?.metadata["size"] == "8")
            #expect(responses.first?.isDirectory == false)
        } else if mode == "json" {
            let infos = try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: bytes)
            #expect(infos.contains { $0.name == "nested/child.txt" })
            #expect(infos.first { $0.name == "link" }?.target == "data.txt")
        } else {
            #expect(bytes.range(of: Data("selected".utf8)) != nil)
            #expect(bytes.range(of: Data("nested-content".utf8)) != nil)
        }
    }
}
