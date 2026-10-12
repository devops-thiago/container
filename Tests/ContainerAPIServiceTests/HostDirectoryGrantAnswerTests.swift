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

@testable import ContainerAPIService

/// The embedder's answer to a request for a folder. These run unsandboxed, so the pool's
/// fallback opens nothing: what `covers` answers is what the pool itself authorizes.
struct HostDirectoryGrantAnswerTests {
    private func poolOnly() -> HostDirectoryGrants {
        HostDirectoryGrants(openable: { _ in false })
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("answer-\(UUID().uuidString)")
            .appendingPathComponent("granted")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @Test("an answer for a folder the app's own publish already pooled is a grant")
    func answerAfterPublishIsGranted() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }
        let answer = try bookmark(granted)

        // The app publishes every grant right after its panel, and that can land first.
        #expect(await pool.publish(bookmarks: [answer]) == 1)
        #expect(await pool.take(answer: answer, for: granted.path) == .granted)
    }

    @Test("an answer alone pools the folder and grants it")
    func answerAloneIsGranted() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.take(answer: try bookmark(granted), for: granted.path) == .granted)
        #expect(await pool.covers(granted.appendingPathComponent("inside").path))
    }

    @Test("an answer for another folder does not grant the one asked for")
    func answerForAnotherFolderIsDeclined() async throws {
        let pool = poolOnly()
        let asked = try folder()
        let other = try folder()
        defer {
            try? FileManager.default.removeItem(at: asked.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: other.deletingLastPathComponent())
        }

        #expect(await pool.take(answer: try bookmark(other), for: asked.path) == .declined)
        #expect(!(await pool.covers(asked.path)))
    }
}
