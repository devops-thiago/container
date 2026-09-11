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

struct CopyHostDirectoryTests {
    @Test(arguments: ["existing file", "new output", "missing parents", "directory"])
    func forwardsOriginalGrantForTheHostOperand(kind: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(kind == "missing parents" ? "new/parents/file with spaces" : "file with spaces")
        if kind == "existing file" { try Data("source".utf8).write(to: file) }
        let path = kind == "directory" ? folder.path : file.path
        let bookmark = Data("the app's original bookmark, not a reminted grant".utf8)
        let expected = folder.standardizedFileURL.path
        let received = try await ContainersService.copyHostDirectoryBookmark(for: path, verb: kind == "new output" ? "write" : "read", sandboxed: true) { requested in
            #expect(requested == expected)
            return (bookmark, .granted)
        }
        #expect(received == bookmark)
    }

    @Test(arguments: ["read", "write"])
    func refusalDoesNotReturnAuthorization(verb: String) async throws {
        for outcome in [HostDirectoryGrants.GrantOutcome.declined, .noEmbedder, .timedOut] {
            do {
                _ = try await ContainersService.copyHostDirectoryBookmark(for: "/Users/Shared/file", verb: verb, sandboxed: true) { _ in
                    // Even an inconsistent reply carrying data cannot override a refusal.
                    (Data([1, 2, 3]), outcome)
                }
                Issue.record("refused grant was forwarded to the runtime")
            } catch {
                #expect(String(describing: error).contains("cannot \(verb) /Users/Shared"))
            }
        }
    }

    @Test func grantedWithoutBookmarkFailsClosed() async {
        await #expect(throws: (any Error).self) {
            try await ContainersService.copyHostDirectoryBookmark(for: "/Users/Shared/file", verb: "write", sandboxed: true) { _ in (nil, .granted) }
        }
    }

    @Test func unsandboxedCopyDoesNotRequestAGrant() async throws {
        let bookmark = try await ContainersService.copyHostDirectoryBookmark(for: "/Users/Shared/file", verb: "write", sandboxed: false) { _ in
            Issue.record("unsandboxed copy asked for permission")
            return (nil, .declined)
        }
        #expect(bookmark == nil)
    }

    @Test func cancellationWhileAskingDiscardsTheReply() async {
        let task = Task {
            try await ContainersService.copyHostDirectoryBookmark(for: "/Users/Shared/file", verb: "read", sandboxed: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (Data([1, 2, 3]), .granted)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelledCopyNeverAsks() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ContainersService.copyHostDirectoryBookmark(for: "/Users/Shared/file", verb: "read", sandboxed: true) { _ in
                Issue.record("cancelled copy asked for permission")
                return (Data([1, 2, 3]), .granted)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
