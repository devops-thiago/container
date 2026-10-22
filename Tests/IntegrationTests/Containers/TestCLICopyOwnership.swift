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

import ContainerTestSupport
import Foundation
import SystemPackage
import Testing

/// Who owns what `container cp` copies into a container, as dockerd decides it: the owner its
/// source names (the host file's, or each tar entry's), and with `-a` the container's user.
@Suite
struct TestCLICopyOwnership {
    /// `uid:gid` of each of `paths` in container `name`, looked at as root.
    static func owners(_ f: ContainerFixture, _ name: String, _ paths: [String]) throws -> [String] {
        try f.doExec(name, cmd: ["stat", "-c", "%u:%g"] + paths, user: "0")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    /// A tar of `names` in `directory` whose entries all name `uid`:`gid` as their owner.
    static func archive(_ names: [String], in directory: FilePath, uid: Int, gid: Int) throws -> Data {
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-c", "-f", "-", "--uid", "\(uid)", "--gid", "\(gid)", "-C", directory.string] + names
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let out = Pipe()
        tar.standardOutput = out
        try tar.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return data
    }

    /// A directory with a file in it, and a file beside it, under the test's directory.
    static func source(_ f: ContainerFixture) throws -> (top: FilePath, host: String) {
        let top = f.testDir.appending("owned")
        try FileManager.default.createDirectory(atPath: top.appending("dir").string, withIntermediateDirectories: true)
        try "inner\n".write(toFile: top.appending("dir/inner.txt").string, atomically: true, encoding: .utf8)
        try "file\n".write(toFile: top.appending("file.txt").string, atomically: true, encoding: .utf8)
        var info = stat()
        #expect(stat(top.appending("file.txt").string, &info) == 0)
        return (top, "\(info.st_uid):\(info.st_gid)")
    }

    @Test func testCopiedFileAndDirectoryKeepTheHostOwner() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let (top, host) = try Self.source(f)
                try f.run(["cp", top.appending("dir").string, "\(name):/tmp/"]).check()
                try f.run(["cp", top.appending("file.txt").string, "\(name):/tmp/"]).check()
                #expect(try Self.owners(f, name, ["/tmp/dir", "/tmp/dir/inner.txt", "/tmp/file.txt"]) == [host, host, host])
            }
        }
    }

    @Test func testStdinTarKeepsItsEntriesOwners() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let (top, _) = try Self.source(f)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/in"])
                let archive = try Self.archive(["dir", "file.txt"], in: top, uid: 1234, gid: 4321)
                try f.run(["cp", "-", "\(name):/tmp/in"], stdin: archive).check()
                #expect(
                    try Self.owners(f, name, ["/tmp/in/dir", "/tmp/in/dir/inner.txt", "/tmp/in/file.txt"])
                        == ["1234:4321", "1234:4321", "1234:4321"])
            }
        }
    }

    @Test func testArchiveModeGivesTheContainerUser() async throws {
        try await ContainerFixture.with { f in
            // alpine's guest is 405 in group users, 100.
            try await f.withContainer(image: WarmupImage.alpine320.rawValue, runArgs: ["--user", "guest"]) { name in
                let (top, _) = try Self.source(f)
                try f.run(["cp", "-a", top.appending("dir").string, "\(name):/tmp/"]).check()
                try f.run(["cp", "--archive", top.appending("file.txt").string, "\(name):/tmp/"]).check()
                #expect(try Self.owners(f, name, ["/tmp/dir", "/tmp/dir/inner.txt", "/tmp/file.txt"]) == ["405:100", "405:100", "405:100"])
            }
        }
    }

    @Test func testCopiedFileKeepsItsModeOverAnExistingFile() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let script = f.testDir.appending("entrypoint.sh")
                try "#!/bin/sh\necho hi\n".write(toFile: script.string, atomically: true, encoding: .utf8)
                #expect(chmod(script.string, 0o755) == 0)
                try f.doExec(name, cmd: ["sh", "-c", "echo old > /tmp/entrypoint.sh && chmod 600 /tmp/entrypoint.sh"])
                try f.run(["cp", script.string, "\(name):/tmp/entrypoint.sh"]).check()
                try f.run(["cp", script.string, "\(name):/tmp/new.sh"]).check()
                #expect(try f.doExec(name, cmd: ["stat", "-c", "%a", "/tmp/entrypoint.sh", "/tmp/new.sh"]) == "755\n755\n")
                #expect(try f.doExec(name, cmd: ["/tmp/entrypoint.sh"]) == "hi\n")
            }
        }
    }

    @Test func testArchiveModeWithoutAUserKeepsTheSourceOwner() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let (top, host) = try Self.source(f)
                try f.run(["cp", "-a", top.appending("file.txt").string, "\(name):/tmp/"]).check()
                #expect(try Self.owners(f, name, ["/tmp/file.txt"]) == [host])
            }
        }
    }
}
