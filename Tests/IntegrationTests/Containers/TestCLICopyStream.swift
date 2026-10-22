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

/// `container cp` with `-`, as `docker cp` has it: `CTR:SRC -` streams a tar of SRC to stdout,
/// `- CTR:DEST` extracts a tar from stdin into the directory DEST.
@Suite
struct TestCLICopyStream {
    /// What `/usr/bin/tar -t` lists in `archive`.
    static func listing(_ archive: Data, in directory: FilePath) throws -> [String] {
        let file = directory.appending("listing-\(UUID().uuidString).tar")
        try archive.write(to: URL(filePath: file.string))
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-tf", file.string]
        let out = Pipe()
        tar.standardOutput = out
        try tar.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// A tar `/usr/bin/tar -c` makes of `names` in `directory`.
    static func archive(_ names: [String], in directory: FilePath) throws -> Data {
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-c", "-f", "-", "-C", directory.string] + names
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let out = Pipe()
        tar.standardOutput = out
        try tar.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return data
    }

    @Test func testFileToStdoutIsOneEntry() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                try f.doExec(name, cmd: ["sh", "-c", "echo hi > /tmp/a.txt"])
                let result = try f.run(["cp", "\(name):/tmp/a.txt", "-"], currentDirectory: f.testDir).check()
                #expect(try Self.listing(result.outputData, in: f.testDir) == ["a.txt"])
                #expect(!FileManager.default.fileExists(atPath: f.testDir.appending("-").string), "no file named - is left behind")
            }
        }
    }

    @Test func testDirectoryToStdoutKeepsItsName() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /tmp/d/sub && echo a > /tmp/d/a && echo b > /tmp/d/sub/b && ln -s a /tmp/d/l"])
                let whole = try f.run(["cp", "\(name):/tmp/d", "-"]).check()
                #expect(try Self.listing(whole.outputData, in: f.testDir) == ["d/", "d/a", "d/l", "d/sub/", "d/sub/b"])
                let contents = try f.run(["cp", "\(name):/tmp/d/.", "-"]).check()
                #expect(try Self.listing(contents.outputData, in: f.testDir) == ["./", "./a", "./l", "./sub/", "./sub/b"])
                let link = try f.run(["cp", "\(name):/tmp/d/l", "-"]).check()
                #expect(try Self.listing(link.outputData, in: f.testDir) == ["l"])
                let followed = try f.run(["cp", "-L", "\(name):/tmp/d/l", "-"]).check()
                #expect(try Self.listing(followed.outputData, in: f.testDir) == ["a"])
            }
        }
    }

    @Test func testMissingSourceIsNotFound() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let result = try f.run(["cp", "\(name):/nope", "-"])
                #expect(result.status == 1)
                #expect(result.error.contains("Could not find the file /nope in container \(name)"))
                #expect(result.outputData.isEmpty)
            }
        }
    }

    @Test func testStdinTarExtractsIntoDirectory() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let source = f.testDir.appending("src")
                try FileManager.default.createDirectory(atPath: source.appending("dir").string, withIntermediateDirectories: true)
                try "f\n".write(toFile: source.appending("f.txt").string, atomically: true, encoding: .utf8)
                try "g\n".write(toFile: source.appending("dir/g.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["mkdir", "-p", "/tmp/in"])
                let archive = try Self.archive(["f.txt", "dir"], in: source)
                let result = try f.run(["cp", "-", "\(name):/tmp/in"], stdin: archive).check()
                #expect(result.outputData.isEmpty)
                #expect(try f.doExec(name, cmd: ["cat", "/tmp/in/f.txt"]) == "f\n")
                #expect(try f.doExec(name, cmd: ["cat", "/tmp/in/dir/g.txt"]) == "g\n")
            }
        }
    }

    @Test func testStdinIntoNonDirectoryIsRefused() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                let source = f.testDir.appending("src")
                try FileManager.default.createDirectory(atPath: source.string, withIntermediateDirectories: true)
                try "f\n".write(toFile: source.appending("f.txt").string, atomically: true, encoding: .utf8)
                try f.doExec(name, cmd: ["sh", "-c", "echo x > /tmp/file"])
                let archive = try Self.archive(["f.txt"], in: source)
                for destination in ["/tmp/nope/", "/tmp/file"] {
                    let result = try f.run(["cp", "-", "\(name):\(destination)"], stdin: archive)
                    #expect(result.status == 1)
                    #expect(result.error.contains("destination \"\(name):\(destination)\" must be a directory"))
                }
            }
        }
    }

    @Test func testDotSlashDashIsALocalFile() async throws {
        try await ContainerFixture.with { f in
            try await f.withContainer(image: WarmupImage.alpine320.rawValue) { name in
                try "literal\n".write(toFile: f.testDir.appending("-").string, atomically: true, encoding: .utf8)
                // A shell sets PWD for the directory it runs a command in; the CLI resolves relative paths from it.
                try f.run(["cp", "./-", "\(name):/tmp/"], currentDirectory: f.testDir, env: ["PWD": f.testDir.string]).check()
                #expect(try f.doExec(name, cmd: ["cat", "/tmp/-"]) == "literal\n")
            }
        }
    }
}
