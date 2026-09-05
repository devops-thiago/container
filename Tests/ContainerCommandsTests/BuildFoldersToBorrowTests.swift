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

@testable import ContainerCommands

struct BuildFoldersToBorrowTests {
    @Test func contextAlone() {
        let folders = Application.BuildCommand.foldersToBorrow(contextDir: "/Users/x/proj", file: nil)
        #expect(folders == ["/Users/x/proj"])
    }

    @Test func dockerfileInsideTheContextAddsNothing() {
        let folders = Application.BuildCommand.foldersToBorrow(
            contextDir: "/Users/x/proj", file: "/Users/x/proj/docker/Dockerfile.dev")
        #expect(folders == ["/Users/x/proj"])
    }

    @Test func dockerfileOutsideTheContextAddsItsFolder() {
        let folders = Application.BuildCommand.foldersToBorrow(
            contextDir: "/Users/x/proj", file: "/Users/x/dockerfiles/Dockerfile")
        #expect(folders == ["/Users/x/proj", "/Users/x/dockerfiles"])
    }

    @Test func aSiblingWithTheSamePrefixIsOutside() {
        let folders = Application.BuildCommand.foldersToBorrow(
            contextDir: "/Users/x/proj", file: "/Users/x/proj-infra/Dockerfile")
        #expect(folders == ["/Users/x/proj", "/Users/x/proj-infra"])
    }

    @Test func stdinBorrowsOnlyTheContext() {
        let folders = Application.BuildCommand.foldersToBorrow(contextDir: "/Users/x/proj", file: "-")
        #expect(folders == ["/Users/x/proj"])
    }

    @Test func relativePathsResolveAgainstTheShellsDirectory() {
        let env = ["PWD": "/Users/x/proj"]
        #expect(Application.BuildCommand.foldersToBorrow(contextDir: ".", file: nil, environment: env) == ["/Users/x/proj"])
        #expect(
            Application.BuildCommand.foldersToBorrow(contextDir: "../other", file: "build/Dockerfile", environment: env)
                == ["/Users/x/other", "/Users/x/proj/build"])
    }

    @Test func withoutAShellDirectoryTheProcessOneIsUsed() {
        let folders = Application.BuildCommand.foldersToBorrow(contextDir: ".", file: nil, environment: [:])
        #expect(folders == [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path])
    }

    @Test func aRelativeShellDirectoryIsIgnored() {
        let folders = Application.BuildCommand.foldersToBorrow(contextDir: ".", file: nil, environment: ["PWD": "relative"])
        #expect(folders == [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path])
    }
}
