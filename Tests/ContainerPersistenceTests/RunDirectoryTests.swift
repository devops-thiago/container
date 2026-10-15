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
import SystemPackage
import Testing

@testable import ContainerPersistence

/// The directory engine services publish sockets in decides who can reach them.
struct RunDirectoryTests {
    private func scratch() throws -> FilePath {
        let url = FileManager.default.temporaryDirectory.appending(path: "rundir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilePath(url.path(percentEncoded: false))
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test("it is created for this user alone")
    func createdPrivate() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(atPath: base.string) }
        let run = try PathUtils.runDirectory(in: base)
        #expect(run.path(percentEncoded: false).hasSuffix("/run/") || run.path(percentEncoded: false).hasSuffix("/run"))
        #expect(mode(base.appending("run").string) == 0o700)
    }

    @Test("an existing one left open is closed to other users")
    func tightensExisting() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(atPath: base.string) }
        let path = base.appending("run").string
        mkdir(path, 0o755)
        chmod(path, 0o755)
        _ = try PathUtils.runDirectory(in: base)
        #expect(mode(path) == 0o700)
    }

    @Test("a symlink or a file in its place is refused, not followed")
    func refusesImpostors() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(atPath: base.string) }
        let elsewhere = try scratch()
        defer { try? FileManager.default.removeItem(atPath: elsewhere.string) }
        symlink(elsewhere.string, base.appending("run").string)
        #expect(throws: (any Error).self) { try PathUtils.runDirectory(in: base) }

        let other = try scratch()
        defer { try? FileManager.default.removeItem(atPath: other.string) }
        FileManager.default.createFile(atPath: other.appending("run").string, contents: Data())
        #expect(throws: (any Error).self) { try PathUtils.runDirectory(in: other) }
    }
}
