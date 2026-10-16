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
import Logging
import NIOCore
import Testing

@testable import DockerAPIService

/// `POST /containers/{id}/rename` on an engine that keeps names (#230): the name label is set in
/// the engine, and is what every client, this service after a restart included, reads.
@Suite(.timeLimit(.minutes(1)))
struct EngineRenameTests {
    @Test("a rename sets the engine's name label and nothing else, and the name resolves from engine data after a restart")
    func renameInEngine() async throws {
        let routes = ContainerRoutesTests()
        routes.engine.keepsNames = true
        let id = try await routes.create("web")
        let engineID = String(id.prefix(12))
        #expect(try await routes.call(.POST, "/containers/web/rename?name=front").status == .noContent)
        #expect(routes.engine.labelsSet == ["\(engineID) \(DockerLabels.name)=front"])
        #expect(routes.engine.snapshot(engineID)?.configuration.labels[DockerLabels.name] == "front")
        #expect(try await routes.call(.GET, "/containers/front/json").status == .ok)
        #expect(try await routes.call(.GET, "/containers/web/json").status == .notFound)

        // This service restarted with nothing kept: the engine's label has the name.
        let restarted = DockerIdentityStore(persistence: nil)
        let joined = await restarted.join(try await routes.engine.list())
        #expect(joined.first { $0.dockerID == id }?.name == "front")

        // Renamed by another client of the engine (the CLI plugin): this service follows.
        routes.engine.update(engineID) { $0.configuration.labels[DockerLabels.name] = "edge" }
        #expect(try await routes.call(.GET, "/containers/edge/json").status == .ok)
        #expect(try await routes.call(.GET, "/containers/front/json").status == .notFound)
    }

    @Test("a name the engine refuses is dockerd's 409, and nothing is renamed")
    func engineConflict() async throws {
        let routes = ContainerRoutesTests()
        routes.engine.keepsNames = true
        _ = try await routes.create("web")
        // Taken in the engine after this service looked: the engine refuses it.
        routes.engine.takenInEngine = ["db"]
        let taken = try await routes.call(.POST, "/containers/web/rename?name=db")
        #expect(taken.status == .conflict)
        #expect(taken.message?.hasPrefix("Error when allocating new name:") == true)
        #expect(routes.engine.labelsSet.isEmpty)
        #expect(try await routes.call(.GET, "/containers/web/json").status == .ok)
    }

    @Test("an engine that does not keep names: the rename is this service's, as before")
    func oldEngine() async throws {
        let routes = ContainerRoutesTests()
        _ = try await routes.create("web")
        #expect(try await routes.call(.POST, "/containers/web/rename?name=front").status == .noContent)
        #expect(routes.engine.labelsSet.isEmpty)
        #expect(try await routes.call(.GET, "/containers/front/json").status == .ok)
    }

    @Test("names renamed here while the engine could not keep them go to the engine once it can")
    func migration() async throws {
        let routes = ContainerRoutesTests()
        let id = try await routes.create("web")
        #expect(try await routes.call(.POST, "/containers/web/rename?name=front").status == .noContent)
        let log = Logger(label: "EngineRenameTests")
        // Still an old engine: nothing moves.
        await ContainerRoutes.moveLocalRenamesToEngine(engine: routes.engine, identities: routes.identities, log: log)
        #expect(routes.engine.labelsSet.isEmpty)
        routes.engine.keepsNames = true
        await ContainerRoutes.moveLocalRenamesToEngine(engine: routes.engine, identities: routes.identities, log: log)
        #expect(routes.engine.labelsSet == ["\(id.prefix(12)) \(DockerLabels.name)=front"])
        #expect(await routes.identities.localRenames(try await routes.engine.list()).isEmpty)
        // Once is enough.
        await ContainerRoutes.moveLocalRenamesToEngine(engine: routes.engine, identities: routes.identities, log: log)
        #expect(routes.engine.labelsSet.count == 1)
        #expect(try await routes.call(.GET, "/containers/front/json").status == .ok)
    }
}
