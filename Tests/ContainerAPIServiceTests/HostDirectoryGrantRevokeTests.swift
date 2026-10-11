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
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient
@testable import ContainerAPIService

/// Revoking a folder from the engine's grant pool. These run unsandboxed, where every folder a
/// test makes is readable, so most use a pool whose fallback opens nothing: what `covers` then
/// answers is what the pool itself authorizes.
struct HostDirectoryGrantRevokeTests {
    /// A pool that authorizes only what was published to it.
    private func poolOnly() -> HostDirectoryGrants {
        HostDirectoryGrants(openable: { _ in false })
    }

    private func folder(_ name: String = "grant", in parent: URL? = nil) throws -> URL {
        let base = parent ?? FileManager.default.temporaryDirectory.appendingPathComponent("revoke-\(UUID().uuidString)")
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("a published folder is covered, and is not once it is revoked")
    func revokeEndsAuthorization() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.covers(granted.path))
        #expect(await pool.covers(granted.appendingPathComponent("src/main.swift").path))

        #expect(await pool.revoke(granted.path) == .revoked([canonical(granted)]))
        #expect(!(await pool.covers(granted.path)))
        #expect(!(await pool.covers(granted.appendingPathComponent("src/main.swift").path)))
    }

    @Test("a revoked folder is refused even when this process can still open it")
    func revokeOverridesReadability() async throws {
        // The real fallback: the folder is readable here, as it would stay in a sandbox while a
        // stopped container still holds its extension. Revoked must still mean not covered.
        let pool = HostDirectoryGrants()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.revoke(granted.path) == .revoked([canonical(granted)]))
        #expect(!(await pool.covers(granted.path)))
        #expect(!(await pool.covers(granted.appendingPathComponent("nested").path)))
    }

    @Test("revoke is idempotent and an unknown folder is reported, not refused")
    func revokeIsIdempotent() async throws {
        let pool = HostDirectoryGrants()
        let granted = try folder()
        let stranger = try folder("never-granted", in: granted.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.revoke(granted.path) == .revoked([canonical(granted)]))
        #expect(await pool.revoke(granted.path) == .notGranted)
        #expect(!(await pool.covers(granted.path)))

        // Nothing was held, so nothing is remembered: a folder this process can open on its own
        // stays openable after a revoke that found no grant for it.
        #expect(await pool.revoke(stranger.path) == .notGranted)
        #expect(await pool.covers(stranger.path))
    }

    @Test("revoking one grant leaves the others, around it, inside it and beside it")
    func otherGrantsAreUnaffected() async throws {
        let pool = poolOnly()
        let outer = try folder("outer")
        let inner = try folder("inner", in: outer)
        let sibling = try folder("sibling", in: outer.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: outer.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(outer), try bookmark(inner), try bookmark(sibling)]) == 3)

        #expect(await pool.revoke(outer.path) == .revoked([canonical(outer)]))
        #expect(await pool.covers(inner.appendingPathComponent("file").path))
        #expect(await pool.covers(sibling.path))
        #expect(!(await pool.covers(outer.appendingPathComponent("elsewhere").path)))

        // And the other way round: revoking the inner grant does not strip the outer one, which
        // still covers it.
        let second = poolOnly()
        #expect(await second.publish(bookmarks: [try bookmark(outer), try bookmark(inner)]) == 2)
        #expect(await second.revoke(inner.path) == .revoked([canonical(inner)]))
        #expect(await second.covers(inner.path))
        #expect(await second.covers(outer.path))
    }

    @Test("a revoke matches the folder however its path is spelled")
    func revokeCanonicalizesThePath() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }
        let resolved = canonical(granted)
        // The temporary directory sits behind /var -> /private/var; name it the other way.
        let spelled = resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : resolved

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.revoke(spelled + "/") == .revoked([resolved]))
        #expect(!(await pool.covers(resolved)))
    }

    @Test("a folder renamed after it was granted is revoked by where it is now")
    func revokeFollowsARename() async throws {
        let pool = poolOnly()
        let granted = try folder("before")
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        let moved = granted.deletingLastPathComponent().appendingPathComponent("after")
        try FileManager.default.moveItem(at: granted, to: moved)

        #expect(await pool.revoke(moved.path) == .revoked([canonical(granted)]))
        #expect(!(await pool.covers(granted.path)))
        #expect(!(await pool.covers(moved.path)))
    }

    @Test("granting a revoked folder again authorizes it again")
    func publishAfterRevokeRestores() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }

        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.revoke(granted.path) == .revoked([canonical(granted)]))
        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)
        #expect(await pool.covers(granted.path))
    }

    @Test("the revoke route needs a path and reports both outcomes")
    func harnessRevokeWireForm() async throws {
        let pool = poolOnly()
        let granted = try folder()
        defer { try? FileManager.default.removeItem(at: granted.deletingLastPathComponent()) }
        #expect(await pool.publish(bookmarks: [try bookmark(granted)]) == 1)

        await #expect(throws: ContainerizationError.self) {
            _ = try await HostDirectoryGrantHarness.revoke(path: nil, in: pool)
        }
        await #expect(throws: ContainerizationError.self) {
            _ = try await HostDirectoryGrantHarness.revoke(path: "", in: pool)
        }
        #expect(try await HostDirectoryGrantHarness.revoke(path: granted.path, in: pool) == .revoked)
        #expect(try await HostDirectoryGrantHarness.revoke(path: granted.path, in: pool) == .notGranted)
    }

    @Test("a revoke is bound to the signed app and its current owner token")
    func revokeRequiresTheOwner() {
        let message = ClientHostDirectory.revokeRequest(path: "/Users/me/src", ownerToken: "current-app-token")
        #expect(message.string(key: XPCMessage.routeKey) == XPCRoute.hostDirectoryGrantRevoke.rawValue)
        #expect(message.string(key: .hostDirectoryPath) == "/Users/me/src")

        #expect(HostDirectoryGrantHarness.authorized(message, peerIsHostApp: true, ownerToken: "current-app-token"))
        #expect(!HostDirectoryGrantHarness.authorized(message, peerIsHostApp: false, ownerToken: "current-app-token"))
        #expect(!HostDirectoryGrantHarness.authorized(message, peerIsHostApp: true, ownerToken: "replacement-token"))
        #expect(!HostDirectoryGrantHarness.authorized(message, peerIsHostApp: true, ownerToken: nil))
    }

    @Test("the client reads both outcomes and refuses a reply that names neither")
    func clientReadsTheOutcome() throws {
        for outcome in [HostDirectoryRevokeOutcome.revoked, .notGranted] {
            let reply = XPCMessage(route: XPCRoute.hostDirectoryGrantRevoke)
            reply.set(key: .hostDirectoryOutcome, value: outcome.rawValue)
            #expect(try ClientHostDirectory.revokeOutcome(reply) == outcome)
        }
        #expect(throws: ContainerizationError.self) {
            _ = try ClientHostDirectory.revokeOutcome(XPCMessage(route: XPCRoute.hostDirectoryGrantRevoke))
        }
    }
}
