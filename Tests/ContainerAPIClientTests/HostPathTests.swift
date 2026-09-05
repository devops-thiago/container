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

@testable import ContainerAPIClient

struct HostPathTests {
    @Test func absolutePathsAreStandardisedOnly() {
        #expect(HostPath.absolute("/Users/x/proj/../proj/./Dockerfile", environment: ["PWD": "/elsewhere"]) == "/Users/x/proj/Dockerfile")
    }

    @Test func relativePathsResolveAgainstTheShellsDirectory() {
        let env = ["PWD": "/Users/x/proj"]
        #expect(HostPath.absolute(".", environment: env) == "/Users/x/proj")
        #expect(HostPath.absolute("build/Dockerfile", environment: env) == "/Users/x/proj/build/Dockerfile")
        #expect(HostPath.absolute("../other", environment: env) == "/Users/x/other")
    }

    @Test func withoutAUsableShellDirectoryTheProcessOneIsUsed() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        #expect(HostPath.absolute(".", environment: [:]) == cwd)
        #expect(HostPath.absolute(".", environment: ["PWD": "relative"]) == cwd)
    }

    @Test func theFolderForAFileOrAMissingPathIsItsParent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hostpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.tar")
        try Data().write(to: file)
        let standardised = folder.standardizedFileURL.path
        #expect(HostPath.folder(for: file.path) == standardised)
        #expect(HostPath.folder(for: folder.appendingPathComponent("not-yet.tar").path) == standardised)
        #expect(HostPath.folder(for: folder.path) == standardised)
    }
}
