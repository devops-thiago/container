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

import ContainerXPC
import Foundation
import Testing

@testable import ContainerAPIClient

struct HostDirectoryLendTests {
    @Test func aReplyWithoutABookmarkCarriesItsOutcome() throws {
        for outcome in [HostDirectoryLendOutcome.declined, .noEmbedder, .timedOut] {
            let reply = XPCMessage(route: XPCRoute.hostDirectoryGrantLend.rawValue)
            reply.set(key: .hostDirectoryOutcome, value: outcome.rawValue)
            #expect(try ClientHostDirectory.accept(reply) == outcome)
        }
    }

    @Test func anEmptyReplyIsADecline() throws {
        let reply = XPCMessage(route: XPCRoute.hostDirectoryGrantLend.rawValue)
        #expect(try ClientHostDirectory.accept(reply) == .declined)
    }

    @Test func aBookmarkThisProcessCanResolveIsAGrant() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let reply = XPCMessage(route: XPCRoute.hostDirectoryGrantLend.rawValue)
        reply.set(key: .hostDirectoryOutcome, value: HostDirectoryLendOutcome.granted.rawValue)
        reply.set(key: .hostDirectoryBookmarks, value: bookmark)
        #expect(try ClientHostDirectory.accept(reply) == .granted)
    }

    @Test func aBookmarkThatDoesNotResolveIsAnError() {
        let reply = XPCMessage(route: XPCRoute.hostDirectoryGrantLend.rawValue)
        reply.set(key: .hostDirectoryBookmarks, value: Data("not a bookmark".utf8))
        #expect(throws: (any Error).self) { try ClientHostDirectory.accept(reply) }
    }

    @Test func everyOutcomeNamesTheFolderAndWhatToDo() {
        let text = HostDirectoryLendOutcome.declined.message(for: "/Users/x/proj", verb: "read")
        #expect(text.contains("/Users/x/proj") && text.contains("declined") && text.contains("choose that folder"))
        let closed = HostDirectoryLendOutcome.noEmbedder.message(for: "/Users/x/proj", verb: "read")
        #expect(closed.contains("Open SiliconShip"))
        let late = HostDirectoryLendOutcome.timedOut.message(for: "/Users/x/proj", verb: "read")
        #expect(late.contains("five minutes"))
    }
}
