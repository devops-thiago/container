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

import ContainerResource
import Foundation
import Testing

@testable import DockerAPIService

/// A store directory the agent cannot write: every change a client asks for answers dockerd's
/// 500 with the reason instead of success, and nothing is left half done.
@Suite(.timeLimit(.minutes(1)))
struct IdentitySaveFailureTests {
    /// The routes over a store kept in a directory of its own, which `lock` makes read-only.
    final class Harness {
        let directory: URL
        let routes: ContainerRoutesTests
        let store: DockerIdentityStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "identity-save-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = DockerIdentityStore(persistence: DockerIdentityFile(directory: directory))
            routes = ContainerRoutesTests(snapshots: [], identities: store)
        }

        func lock() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false))
        }

        func unlock() throws {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        }

        /// The names the store has on disk.
        func saved() throws -> [String] {
            try DockerIdentityFile(directory: directory).load().map(\.name).sorted()
        }

        deinit {
            try? unlock()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("a create whose identity cannot be saved answers 500 and leaves no container, volume or name behind")
    func create() async throws {
        let harness = try Harness()
        let routes = harness.routes
        try harness.lock()
        let failed = try await routes.call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine","Volumes":{"/data":{}}}"#)
        #expect(failed.status == .internalServerError)
        #expect(failed.message?.hasPrefix("could not keep the new container's identity: ") == true)
        #expect(failed.message?.hasSuffix("/containers.json: Permission denied") == true)
        // As dockerd removes a container it could not write to disk: force, with its volumes.
        let plan = try #require(routes.engine.plans.first)
        let anonymous = try #require(plan.extras.anonymousVolumes.first)
        #expect(routes.engine.calls.suffix(2) == ["delete \(plan.configuration.id) true", "volume rm \(anonymous)"])
        #expect(routes.engine.snapshot(plan.configuration.id) == nil)
        #expect(await harness.store.records.isEmpty)

        // Control: once the store can be written, the same create succeeds under the same name.
        try harness.unlock()
        #expect(try await routes.call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine"}"#).status == .created)
        #expect(try harness.saved() == ["web"])
    }

    @Test("a rename whose name cannot be saved answers 500 and keeps the old name, here and in an engine that keeps names")
    func rename() async throws {
        for keepsNames in [false, true] {
            let harness = try Harness()
            let routes = harness.routes
            routes.engine.keepsNames = keepsNames
            let id = try await routes.create("web")
            let engineID = String(id.prefix(12))
            try harness.lock()
            let failed = try await routes.call(.POST, "/containers/web/rename?name=front")
            #expect(failed.status == .internalServerError, "keepsNames \(keepsNames)")
            #expect(failed.message?.hasPrefix("could not keep the new name: ") == true, "keepsNames \(keepsNames)")
            #expect(try await routes.call(.GET, "/containers/web/json").status == .ok, "keepsNames \(keepsNames)")
            #expect(try await routes.call(.GET, "/containers/front/json").status == .notFound, "keepsNames \(keepsNames)")
            if keepsNames {
                // The engine had the new name: it gets the old one back.
                #expect(routes.engine.labelsSet == ["\(engineID) \(DockerLabels.name)=front", "\(engineID) \(DockerLabels.name)=web"])
                #expect(routes.engine.snapshot(engineID)?.configuration.labels[DockerLabels.name] == "web")
            }

            // Control: once the store can be written, the rename succeeds.
            try harness.unlock()
            #expect(try await routes.call(.POST, "/containers/web/rename?name=front").status == .noContent, "keepsNames \(keepsNames)")
            #expect(try harness.saved() == ["front"], "keepsNames \(keepsNames)")
        }
    }

    @Test("a delete whose removal cannot be saved answers 500 once the container and, with v, its volumes are gone")
    func delete() async throws {
        let harness = try Harness()
        let routes = harness.routes
        _ = try await routes.call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine","Volumes":{"/data":{}}}"#)
        let plan = try #require(routes.engine.plans.first)
        let anonymous = try #require(plan.extras.anonymousVolumes.first)
        try harness.lock()
        let failed = try await routes.call(.DELETE, "/containers/web?v=1")
        #expect(failed.status == .internalServerError)
        #expect(failed.message?.hasPrefix("could not forget the removed container: ") == true)
        #expect(routes.engine.calls.suffix(2) == ["delete \(plan.configuration.id) false", "volume rm \(anonymous)"])
        #expect(routes.engine.snapshot(plan.configuration.id) == nil)
        #expect(try await routes.call(.GET, "/containers/web/json").status == .notFound)
        #expect(try harness.saved() == ["web"])

        // Control: the record left on disk goes at the next save, once the store can be written.
        try harness.unlock()
        _ = try await routes.create("db")
        #expect(try harness.saved() == ["db"])
    }
}
