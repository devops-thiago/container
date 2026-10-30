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

import ArgumentParser
import Darwin
import Foundation
import Testing

@testable import ContainerCommands

/// `container build --progress`, which `compose build` and `compose up` run too: plain lines
/// unless standard error is a terminal, as Docker's buildx decides for `auto`.
struct BuildProgressTests {
    private typealias Build = BuildOptions

    /// Both ends of a pipe, closed when the test is done.
    private static func withPipe(_ body: (Int32) throws -> Void) throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        try body(fds[1])
    }

    /// A pseudo-terminal's device, as a terminal or node-pty gives a process.
    private static func withTerminal(_ body: (Int32) throws -> Void) throws {
        var primary: Int32 = -1
        var device: Int32 = -1
        try #require(openpty(&primary, &device, nil, nil, nil) == 0)
        defer {
            close(device)
            close(primary)
        }
        try body(device)
    }

    @Test
    func autoIsPlainLinesThroughAPipe() throws {
        try Self.withPipe { fd throws in
            #expect(try Build.progressTerminal(.auto, descriptor: fd) == nil)
            #expect(try Build.progressTerminal(.plain, descriptor: fd) == nil)
        }
    }

    @Test
    func autoIsPlainLinesIntoAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("build-progress-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        #expect(try Build.progressTerminal(.auto, descriptor: handle.fileDescriptor) == nil)
    }

    @Test
    func autoDrawsOnATerminal() throws {
        try Self.withTerminal { fd throws in
            #expect(try Build.progressTerminal(.auto, descriptor: fd) != nil)
            #expect(try Build.progressTerminal(.tty, descriptor: fd) != nil)
            #expect(try Build.progressTerminal(.plain, descriptor: fd) == nil, "--progress plain is plain on a terminal too")
        }
    }

    @Test
    func ttyWithoutATerminalIsAnError() throws {
        try Self.withPipe { fd throws in
            #expect(throws: (any Error).self) { try Build.progressTerminal(.tty, descriptor: fd) }
        }
    }

    @Test
    func progressDefaultsToAuto() throws {
        #expect(try Build.parse(["."]).progress == .auto)
        #expect(try Build.parse(["--progress", "plain", "."]).progress == .plain)
        #expect(try Build.parse(["--progress", "tty", "."]).progress == .tty)
    }
}
