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

@testable import ContainerRuntimeLinuxServer

struct CopyHostAccessTests {
    @Test(arguments: [false, true])
    func resolvesGrantForExistingSourceAndNewDestination(existing: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("file with spaces")
        if existing { try Data("source".utf8).write(to: file) }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let access = try #require(try RuntimeService.copyHostAccess(bookmark: bookmark, path: file.path, sandboxed: true))
        defer { access.stopAccessingSecurityScopedResource() }
        #expect(access.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        if existing {
            #expect(try Data(contentsOf: file) == Data("source".utf8))
        } else {
            try Data("output".utf8).write(to: file)
            #expect(try Data(contentsOf: file) == Data("output".utf8))
        }
    }

    @Test func missingGrantIsOnlyAllowedWithoutASandbox() throws {
        #expect(try RuntimeService.copyHostAccess(bookmark: nil, path: "/Users/Shared/file", sandboxed: false) == nil)
        #expect(throws: (any Error).self) {
            try RuntimeService.copyHostAccess(bookmark: nil, path: "/Users/Shared/file", sandboxed: true)
        }
    }

    @Test func malformedBookmarkFailsClosed() {
        #expect(throws: (any Error).self) {
            try RuntimeService.copyHostAccess(bookmark: Data([1, 2, 3]), path: "/Users/Shared/file", sandboxed: true)
        }
    }

    @Test func unrelatedSiblingAndEscapingSymlinkAreRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("grant")
        let sibling = base.appendingPathComponent("grant-other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: sibling)
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        for path in [sibling.path, folder.appendingPathComponent("escape/output").path, folder.appendingPathComponent("escape/new/parents/output").path] {
            #expect(throws: (any Error).self) {
                try RuntimeService.copyHostAccess(bookmark: bookmark, path: path, sandboxed: true)
            }
        }
        let access = try #require(try RuntimeService.copyHostAccess(bookmark: bookmark, path: folder.path, sandboxed: true))
        access.stopAccessingSecurityScopedResource()
    }
}
