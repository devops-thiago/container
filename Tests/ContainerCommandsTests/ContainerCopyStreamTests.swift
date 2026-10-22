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
import ContainerizationError
import Testing

@testable import ContainerCommands

/// `container cp` reads `-` as `docker cp` does: a tar on stdin as the source, on stdout as the
/// destination; a file named `-` is `./-`.
struct ContainerCopyStreamTests {
    typealias Copy = Application.ContainerCopy

    @Test("- is the stream, not a file named -")
    func dashIsTheStream() throws {
        #expect(try Copy.parsePathRef("-") == .stream)
    }

    @Test("./- and other local paths stay local files")
    func dotSlashDashIsAFile() throws {
        #expect(try Copy.parsePathRef("./-") == .local("./-"))
        #expect(try Copy.parsePathRef("--") == .local("--"))
        #expect(try Copy.parsePathRef("ctr:/etc/hostname") == .container(id: "ctr", path: "/etc/hostname"))
    }

    @Test("-L and --follow-link parse, as docker cp takes them")
    func followLink() throws {
        let short = try #require(try Application.parseAsRoot(["cp", "-L", "ctr:/link", "-"]) as? Copy)
        #expect(short.followLink)
        let long = try #require(try Application.parseAsRoot(["copy", "--follow-link", "ctr:/link", "-"]) as? Copy)
        #expect(long.followLink)
        let plain = try #require(try Application.parseAsRoot(["cp", "ctr:/link", "-"]) as? Copy)
        #expect(!plain.followLink)
    }

    @Test("- on both sides, or with a local path, names no container: Docker's error")
    func noContainer() async throws {
        for arguments in [["-", "-"], ["-", "./x"], ["./x", "-"]] {
            let copy = try #require(try Application.parseAsRoot(["cp"] + arguments) as? Copy)
            let error = await #expect(throws: ContainerizationError.self) {
                try await copy.run()
            }
            #expect(error?.message == "must specify at least one container source")
        }
    }
}
