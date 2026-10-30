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
import Testing

struct MachineRunArgumentsTests {
    private struct Result {
        let status: Int32
        let output: String
        let error: String
        let injected: Bool
    }

    /// Execute the shipped guest script, rather than a copy of its command logic.
    private func run(_ arguments: [String], input: String? = nil) throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-argv-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("wildcard-target"))
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plugins/MachineAPIServer/Resources/init")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "-s"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            error: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            injected: FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path)
        )
    }

    @Test(arguments: [
        "two words", "", "'single' \"double\"", "*", "first\nsecond", "$(printf injected)",
        "`printf injected`", "; /usr/bin/touch injected", "one\\two", "$HOME",
    ])
    func preservesLiteralArguments(argument: String) throws {
        let result = try run(["/usr/bin/printf", "%s,", "before", argument, "after"])
        #expect(result.status == 0, "\(result.error)")
        #expect(result.output == "before," + argument + ",after,")
        #expect(!result.injected, "Argument text must never be evaluated as a shell command")
    }

    @Test func explicitShellPreservesScriptArgumentsAndExitStatus() throws {
        let result = try run(["/bin/sh", "-c", "printf '%s' \"$1\"; exit 23", "audit-shell", "two words"])
        #expect(result.status == 23, "\(result.error)")
        #expect(result.output == "two words")
    }

    @Test func noCommandStillOpensTheUserShell() throws {
        let result = try run([], input: "printf interactive-ok\nexit 19\n")
        #expect(result.status == 19, "\(result.error)")
        #expect(result.output == "interactive-ok")
    }
}
