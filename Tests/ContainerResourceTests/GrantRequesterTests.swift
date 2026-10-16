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

import Darwin
import Foundation
import Testing

@testable import ContainerResource

/// The name a folder-permission panel shows for whoever asked: what is stripped, how long it may
/// be, and how a process is described.
struct GrantRequesterTests {
    @Test(
        "control and bidirectional formatting characters are removed",
        arguments: [
            ("doc\nker", "docker"),
            ("doc\tker", "docker"),
            ("doc\0ker", "docker"),
            ("doc\u{1B}[2Jker", "doc[2Jker"),
            ("doc\u{7F}ker", "docker"),
            ("doc\u{85}ker", "docker"),
            ("doc\u{9B}ker", "docker"),
            ("doc\r\nker", "docker"),
            ("\u{202E}rekcod", "rekcod"),
            ("a\u{200E}b\u{200F}c\u{061C}d\u{2066}e\u{2069}f\u{202A}g", "abcdefg"),
            ("  docker (pid 1)\n", "docker (pid 1)"),
        ])
    func strips(raw: String, expected: String) {
        #expect(GrantRequester.sanitized(raw) == expected)
    }

    @Test(
        "ordinary names are kept exactly, letters of any script and emoji included",
        arguments: ["docker (pid 42)", "com.docker.cli (pid 7)", "café", "测试工具", "Xcode 🛠", "java", "pid 9"])
    func keeps(name: String) {
        #expect(GrantRequester.sanitized(name) == name)
        // Sanitizing twice changes nothing.
        #expect(GrantRequester.sanitized(GrantRequester.sanitized(name)) == name)
    }

    @Test("nothing showable is nil")
    func empty() {
        #expect(GrantRequester.sanitized(nil) == nil)
        #expect(GrantRequester.sanitized("") == nil)
        #expect(GrantRequester.sanitized("   \n\t") == nil)
        #expect(GrantRequester.sanitized("\u{1B}\u{7}\u{202E}") == nil)
    }

    @Test("the length is bounded to 64 characters")
    func bounded() {
        let exact = String(repeating: "a", count: GrantRequester.maxLength)
        #expect(GrantRequester.sanitized(exact) == exact)
        let over = exact + "b"
        #expect(GrantRequester.sanitized(over) == exact)
        // Characters, not bytes: a name of multi-byte letters is not cut short.
        let wide = String(repeating: "é", count: GrantRequester.maxLength + 10)
        #expect(GrantRequester.sanitized(wide)?.count == GrantRequester.maxLength)
        // What is stripped does not count toward the bound.
        let padded = String(repeating: "\u{7}", count: 100) + "docker"
        #expect(GrantRequester.sanitized(padded) == "docker")
    }

    @Test("a process is its name and pid, its pid alone when the name is unknown, and nothing for no process")
    func describing() {
        #expect(GrantRequester.describe(pid: 4242) { _ in "docker" } == "docker (pid 4242)")
        #expect(GrantRequester.describe(pid: 4242) { _ in nil } == "pid 4242")
        #expect(GrantRequester.describe(pid: 4242) { _ in "\n" } == "pid 4242")
        #expect(GrantRequester.describe(pid: 4242) { _ in "ja\u{1B}va" } == "java (pid 4242)")
        #expect(GrantRequester.describe(pid: 0) { _ in "docker" } == nil)
        #expect(GrantRequester.describe(pid: -3) { _ in "docker" } == nil)
        // A long name is shortened, never the pid.
        let long = GrantRequester.describe(pid: 2_147_483_647) { _ in String(repeating: "n", count: 300) }
        #expect(long?.count == GrantRequester.maxLength)
        #expect(long?.hasSuffix(" (pid 2147483647)") == true)
    }

    @Test("the system names another process by its executable")
    func processName() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        #expect(GrantRequester.processName(of: sleeper.processIdentifier) == "sleep")
        #expect(GrantRequester.describe(pid: sleeper.processIdentifier) == "sleep (pid \(sleeper.processIdentifier))")
        // Control: no process has pid 0 to name.
        #expect(GrantRequester.processName(of: 0) == nil)
    }
}
