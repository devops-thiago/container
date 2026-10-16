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

struct ContainerIdentityTests {
    /// A generator that always gives the same sequence, for IDs a test can predict.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test("a labelled container is known by its labels, and a foreign one by the hash of its engine ID")
    func joinIdentities() {
        let ours = Fixtures.dockerContainer(name: "web", dockerID: Fixtures.id("abc123def456"))
        let foreign = Fixtures.snapshot(Fixtures.configuration(id: "my-app"))
        var table = DockerIdentityTable()
        let joined = table.join([ours, foreign])
        #expect(joined[0].dockerID == Fixtures.id("abc123def456"))
        #expect(joined[0].name == "web")
        #expect(joined[1].dockerID == DockerIdentityTable.foreignID(engineID: "my-app"))
        #expect(joined[1].dockerID.count == 64)
        #expect(joined[1].name == "my-app")
        // The labelled one gets a record back; the foreign one needs none.
        #expect(table.records.keys.sorted() == ["abc123def456"])
        // Control: a label whose ID does not start with the engine ID is not believed. Its name
        // label is the engine's name for it, as for any container renamed in the engine.
        var forged = Fixtures.configuration(id: "other")
        forged.labels = [DockerLabels.id: Fixtures.id("abc123def456"), DockerLabels.name: "web"]
        let joinedForged = table.join([Fixtures.snapshot(forged)])[0]
        #expect(joinedForged.dockerID == DockerIdentityTable.foreignID(engineID: "other"))
        #expect(joinedForged.name == "web")
        forged.labels = [DockerLabels.id: Fixtures.id("abc123def456")]
        #expect(table.join([Fixtures.snapshot(forged)])[0].name == "other")
    }

    @Test("SHA-256 of the engine ID is the foreign Docker ID")
    func foreignID() {
        #expect(DockerIdentityTable.foreignID(engineID: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(DockerIdentityTable.foreignID(engineID: "abd") != DockerIdentityTable.foreignID(engineID: "abc"))
    }

    @Test("a record outlives nothing: a deleted container, or another made under the same ID, drops it")
    func recordsFollowIncarnations() {
        var table = DockerIdentityTable(records: [
            DockerContainerRecord(engineID: "abc123def456", incarnation: "inc-1", dockerID: Fixtures.id("abc123def456"), name: "renamed")
        ])
        let snapshot = Fixtures.dockerContainer(name: "web", dockerID: Fixtures.id("abc123def456"))
        #expect(table.join([snapshot])[0].name == "renamed")
        var remade = snapshot
        remade = ContainerSnapshot(configuration: remade.configuration, incarnation: "inc-2", status: .running, networks: [])
        #expect(table.join([remade])[0].name == "web")
        _ = table.join([])
        #expect(table.records.isEmpty)
    }

    @Test("a reference is a full ID, then a name with or without a slash, then a unique prefix")
    func resolve() throws {
        let a = DockerContainer(snapshot: Fixtures.snapshot(Fixtures.configuration(id: "a")), dockerID: Fixtures.id("abc1"), name: "alpha")
        let b = DockerContainer(snapshot: Fixtures.snapshot(Fixtures.configuration(id: "b")), dockerID: Fixtures.id("abc2"), name: "beta")
        // A name that is also a prefix of another container's ID is the name.
        let c = DockerContainer(snapshot: Fixtures.snapshot(Fixtures.configuration(id: "c")), dockerID: Fixtures.id("fff"), name: "abc1")
        let all = [a, b, c]
        #expect(try DockerIdentityTable.resolve(Fixtures.id("abc2"), in: all).name == "beta")
        #expect(try DockerIdentityTable.resolve("beta", in: all).name == "beta")
        #expect(try DockerIdentityTable.resolve("/beta", in: all).name == "beta")
        #expect(try DockerIdentityTable.resolve("abc1", in: all).name == "abc1")
        #expect(try DockerIdentityTable.resolve("abc2", in: all).name == "beta")
        #expect(throws: DockerAPIError.badRequest("multiple IDs found with provided prefix: abc")) { try DockerIdentityTable.resolve("abc", in: all) }
        #expect(throws: DockerAPIError.notFound("No such container: zzz")) { try DockerIdentityTable.resolve("zzz", in: all) }
        #expect(throws: DockerAPIError.notFound("No such container: /abc2")) { try DockerIdentityTable.resolve("/abc2", in: all) }
    }

    @Test("a reservation takes a name and a fresh ID whose engine ID is free; a taken name is dockerd's 409")
    func reserve() async throws {
        let store = DockerIdentityStore(persistence: nil, generator: SeededGenerator(state: 1))
        let existing = [
            DockerContainer(snapshot: Fixtures.snapshot(Fixtures.configuration(id: "x")), dockerID: Fixtures.id("abc"), name: "web")
        ]
        let reservation = try await store.reserve(name: "/api", among: existing)
        #expect(reservation.name == "api")
        #expect(DockerIdentityTable.isDockerID(reservation.dockerID))
        #expect(reservation.engineID == String(reservation.dockerID.prefix(12)))
        await #expect(
            throws: DockerAPIError.conflict(
                "Conflict. The container name \"/web\" is already in use by container \"\(Fixtures.id("abc"))\". You have to remove (or rename) that container to be able to reuse that name."
            )
        ) { try await store.reserve(name: "web", among: existing) }
        // A name reserved by a create in flight is taken too, until it is released.
        await #expect(throws: DockerAPIError.self) { try await store.reserve(name: "api", among: existing) }
        await store.release(reservation)
        #expect(try await store.reserve(name: "api", among: existing).name == "api")
        await #expect(throws: DockerAPIError.badRequest("Invalid container name (-bad), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")) {
            try await store.reserve(name: "-bad", among: existing)
        }
        // Control: no name gets a generated one.
        let generated = try await store.reserve(name: nil, among: existing)
        #expect(generated.name.contains("_"))
        #expect(DockerIdentityTable.isValidName(generated.name))
    }

    @Test("rename is the store's: refused when taken, the same, or empty, and kept across a restart")
    func rename() async throws {
        let persistence = MemoryIdentityPersistence()
        let store = DockerIdentityStore(persistence: persistence)
        let web = Fixtures.dockerContainer(name: "web", dockerID: Fixtures.id("abc123def456"))
        let foreign = Fixtures.snapshot(Fixtures.configuration(id: "my-app"))
        var all = await store.join([web, foreign])
        try await store.rename(all[0], to: "/front", among: all)
        await #expect(throws: DockerAPIError.badRequest("Renaming a container with the same name as its current name")) {
            try await store.rename(all[1], to: "my-app", among: all)
        }
        await #expect(throws: DockerAPIError.badRequest("Neither old nor new names may be empty")) { try await store.rename(all[1], to: "", among: all) }
        all = await store.join([web, foreign])
        await #expect(throws: DockerAPIError.self) { try await store.rename(all[1], to: "front", among: all) }
        do {
            try await store.rename(all[1], to: "front", among: all)
        } catch let error as DockerAPIError {
            #expect(error.status == .conflict)
            #expect(error.message.hasPrefix("Error when allocating new name: Conflict. The container name \"/front\""))
        }
        // A foreign container can be renamed too, and keeps its hashed ID.
        try await store.rename(all[1], to: "legacy", among: all)

        let restarted = DockerIdentityStore(persistence: persistence)
        let rejoined = await restarted.join([web, foreign])
        #expect(rejoined.map(\.name) == ["front", "legacy"])
        #expect(rejoined[1].dockerID == DockerIdentityTable.foreignID(engineID: "my-app"))
        // Control: a store that lost its file falls back to the labels and the engine IDs.
        #expect(await DockerIdentityStore(persistence: nil).join([web, foreign]).map(\.name) == ["web", "my-app"])
    }

    @Test("records go to disk owner-only and come back; a missing file is an empty store")
    func fileRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dapi-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DockerIdentityFile(directory: directory)
        #expect(try file.load().isEmpty)
        let record = DockerContainerRecord(
            engineID: "abc123def456", incarnation: "inc", dockerID: Fixtures.id("abc123def456"), name: "web",
            extras: DockerContainerExtras(image: "alpine", imageID: Fixtures.configDigest, cmd: ["sh"], openStdin: true, anonymousVolumes: ["v1"]))
        try file.save([record])
        #expect(try file.load() == [record])
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Control: a corrupt file is an error to the file, and an empty start to the store.
        try Data("{".utf8).write(to: file.url)
        #expect(throws: (any Error).self) { try file.load() }
    }

    @Test("commit records the create and forget drops it, each saved")
    func commitAndForget() async throws {
        let persistence = MemoryIdentityPersistence()
        let store = DockerIdentityStore(persistence: persistence)
        let reservation = try await store.reserve(name: "web", among: [])
        await store.commit(reservation, incarnation: "inc-9", extras: DockerContainerExtras(image: "alpine", imageID: "sha256:x"))
        #expect(persistence.records.map(\.name) == ["web"])
        #expect(persistence.records.first?.incarnation == "inc-9")
        await store.forget(engineID: reservation.engineID)
        #expect(persistence.records.isEmpty)
        // Control: forgetting a container with no record writes nothing.
        let saves = persistence.saves
        await store.forget(engineID: "unknown")
        #expect(persistence.saves == saves)
    }

    @Test("the name is the label's: a rename in the engine wins over the record, which only caches it")
    func labelIsTheName() {
        var table = DockerIdentityTable(records: [
            DockerContainerRecord(engineID: "abc123def456", incarnation: "inc-1", dockerID: Fixtures.id("abc123def456"), name: "web", localRename: false)
        ])
        // Renamed in the engine, by this service or by another client of it.
        let renamed = Fixtures.dockerContainer(name: "front", dockerID: Fixtures.id("abc123def456"))
        #expect(table.join([renamed])[0].name == "front")
        #expect(table.records["abc123def456"]?.name == "front")
        // A container the engine renamed that this service never made.
        var foreign = Fixtures.configuration(id: "my-app")
        foreign.labels = [DockerLabels.name: "legacy"]
        #expect(table.join([Fixtures.snapshot(foreign)])[0].name == "legacy")
    }

    @Test("a rename the engine could not keep wins over the label until it has it; one from before names lived in the engine is one too")
    func localRenames() async {
        let web = Fixtures.dockerContainer(name: "web", dockerID: Fixtures.id("abc123def456"))
        for record in [
            DockerContainerRecord(engineID: "abc123def456", incarnation: "inc-1", dockerID: Fixtures.id("abc123def456"), name: "front", localRename: true),
            // Written by #229, which had no flag: the name differs from the label's.
            DockerContainerRecord(engineID: "abc123def456", incarnation: "inc-1", dockerID: Fixtures.id("abc123def456"), name: "front"),
        ] {
            var table = DockerIdentityTable(records: [record])
            #expect(table.join([web])[0].name == "front")
            #expect(table.records["abc123def456"]?.localRename == true)
        }
        // Control: a #229 record with the label's name is no rename.
        var table = DockerIdentityTable(records: [
            DockerContainerRecord(engineID: "abc123def456", incarnation: "inc-1", dockerID: Fixtures.id("abc123def456"), name: "web")
        ])
        #expect(table.join([web])[0].name == "web")
        #expect(table.records["abc123def456"]?.localRename == false)

        let store = DockerIdentityStore(persistence: nil)
        _ = await store.join([web])
        let all = await store.join([web])
        try? await store.rename(all[0], to: "front", among: all)
        #expect(await store.localRenames([web]).map(\.1) == ["front"])
        await store.renamedInEngine(all[0], to: "front")
        #expect(await store.localRenames([web]).isEmpty)
    }
}
