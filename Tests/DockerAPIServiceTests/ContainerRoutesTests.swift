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
import NIOCore
import NIOHTTP1
import Testing

@testable import DockerAPIService

/// An engine in memory: containers made by create, with the lifecycle the routes drive. A
/// bootstrap makes a `FakeProcess` that runs the container's program, if one was given for
/// it, or waits to be stopped.
final class FakeEngine: EngineContainers, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ContainerSnapshot]
    private var creates = 0
    private var port: UInt16 = 41000
    var images: [String: DockerImageDefaults]
    private(set) var calls: [String] = []
    private(set) var plans: [DockerCreatePlan] = []
    /// What each bootstrap bound, as `"<id> stdin stdout stderr"` with `-` for a missing stream.
    private(set) var bootstraps: [String] = []
    /// Who each create and bootstrap was for, as `"create <requester>"` and
    /// `"bootstrap <id> <requester>"`, with `-` for none.
    private(set) var requesters: [String] = []
    private var processes: [String: FakeProcess] = [:]
    /// The program a container's process runs; without one it waits to be stopped.
    var programs: [String: FakeProgram] = [:]
    /// Containers the engine deletes itself when their process exits, as `--rm` asks.
    var autoRemove: Set<String> = []
    /// Containers in which something keeps stdout open after the process exits.
    var holdOutputOpen: Set<String> = []
    /// The next bootstrap fails with this.
    var bootstrapError: (any Error)?
    /// The next process start fails with this.
    var startError: (any Error)?

    init(snapshots: [ContainerSnapshot] = [], images: [String: DockerImageDefaults] = ["alpine": Fixtures.image()]) {
        self.snapshots = snapshots
        self.images = images
    }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    func update(_ id: String, _ change: (inout ContainerSnapshot) -> Void) {
        lock.withLock {
            if let index = snapshots.firstIndex(where: { $0.id == id }) { change(&snapshots[index]) }
        }
    }

    func snapshot(_ id: String) -> ContainerSnapshot? {
        lock.withLock { snapshots.first { $0.id == id } }
    }

    func process(_ id: String) -> FakeProcess? {
        lock.withLock { processes[id] }
    }

    /// Holds the next list once it has read the containers, before it answers.
    var listGate: ListGate?

    func list() async throws -> [ContainerSnapshot] {
        let (listed, gate) = lock.withLock {
            defer { listGate = nil }
            return (snapshots, listGate)
        }
        await gate?.hold()
        return listed
    }

    func get(_ engineID: String) async throws -> ContainerSnapshot? {
        snapshot(engineID)
    }

    func builtinNetwork() async throws -> String? { Fixtures.builtin }

    func image(_ reference: String, platform: String?) async throws -> DockerImageDefaults? {
        lock.withLock { images[reference] }
    }

    func createDefaults() async throws -> DockerCreateDefaults { Fixtures.defaults }

    func allocatePort() throws -> UInt16 {
        lock.withLock {
            port += 1
            return port
        }
    }

    func create(_ plan: DockerCreatePlan, requester: String?) async throws -> String {
        lock.withLock {
            requesters.append("create \(requester ?? "-")")
            creates += 1
            plans.append(plan)
            var configuration = plan.configuration
            configuration.creationDate = Fixtures.now.addingTimeInterval(Double(creates))
            snapshots.append(
                ContainerSnapshot(configuration: configuration, incarnation: "inc-\(creates)", status: .stopped, networks: []))
            if plan.autoRemove { autoRemove.insert(configuration.id) }
            return "inc-\(creates)"
        }
    }

    func bootstrap(_ container: ContainerSnapshot, stdio: DockerProcessStdio, requester: String?) async throws -> any EngineProcess {
        let id = container.id
        let failure: (any Error)? = lock.withLock {
            requesters.append("bootstrap \(id) \(requester ?? "-")")
            let names = [stdio.stdin, stdio.stdout, stdio.stderr].enumerated().map { $1 == nil ? "-" : ["stdin", "stdout", "stderr"][$0] }
            bootstraps.append(([id] + names).joined(separator: " "))
            defer { bootstrapError = nil }
            return bootstrapError
        }
        if let failure { throw failure }
        let process = try FakeProcess(id: id, stdio: stdio, holdOutputOpen: lock.withLock { holdOutputOpen.contains(id) }) { [weak self] process in
            guard let self else { return }
            let failure: (any Error)? = self.lock.withLock {
                defer { self.startError = nil }
                return self.startError
            }
            if let failure { throw failure }
            self.record("start \(id)")
            self.update(id) {
                $0.status = .running
                $0.startedDate = Fixtures.now
                $0.exitCode = nil
                $0.exitedAt = nil
            }
            process.run(self.lock.withLock { self.programs[id] })
        } onExit: { [weak self] code in
            guard let self else { return }
            let remove = self.lock.withLock { self.autoRemove.contains(id) }
            self.update(id) {
                $0.status = .stopped
                $0.exitCode = code
                $0.exitedAt = Fixtures.now.addingTimeInterval(1)
            }
            if remove {
                self.lock.withLock { self.snapshots.removeAll { $0.id == id } }
            }
        }
        lock.withLock { processes[id] = process }
        return process
    }

    func stop(_ container: ContainerSnapshot, timeout: Int32, signal: String?) async throws {
        record("stop \(container.id) \(timeout) \(signal ?? "-")")
        if let process = process(container.id), await process.exit(0) {
            return
        }
        update(container.id) {
            $0.status = .stopped
            $0.exitCode = 0
            $0.exitedAt = Fixtures.now
        }
    }

    func kill(_ container: ContainerSnapshot, signal: String) async throws {
        record("kill \(container.id) \(signal)")
        if let process = process(container.id), await process.exit(137) {
            return
        }
        update(container.id) {
            $0.status = .stopped
            $0.exitCode = 137
            $0.exitedAt = Fixtures.now
        }
    }

    func delete(_ container: ContainerSnapshot, force: Bool) async throws {
        record("delete \(container.id) \(force)")
        if let process = process(container.id) {
            _ = await process.exit(137)
        }
        lock.withLock { snapshots.removeAll { $0.id == container.id } }
    }

    func deleteVolume(_ name: String) async throws {
        record("volume rm \(name)")
    }

    /// Whether this engine keeps names, as one with the label route does.
    var keepsNames = false
    /// Names another client of the engine took after this service last listed.
    var takenInEngine: Set<String> = []
    /// Every label a rename set, as `"<id> <key>=<value>"`.
    private(set) var labelsSet: [String] = []

    func supportsRename() async -> Bool { lock.withLock { keepsNames } }

    /// What each container wrote, by engine ID, as the engine measures it; one not here is
    /// one the engine cannot measure.
    var writableSizes: [String: Int64] = [:]

    func writableSize(_ container: ContainerSnapshot) async -> Int64? {
        lock.withLock { writableSizes[container.id] }
    }

    func rename(_ container: ContainerSnapshot, to name: String) async throws {
        try lock.withLock {
            guard keepsNames else { throw DockerAPIError.notImplemented("no label route") }
            // As the engine does: a name another container holds is refused, and so is one
            // taken since the caller looked.
            if takenInEngine.contains(name) || snapshots.contains(where: { $0.id != container.id && DockerIdentityTable.engineName($0) == name }) {
                throw DockerAPIError.conflict("the name \(name) is already in use")
            }
            labelsSet.append("\(container.id) \(DockerLabels.name)=\(name)")
            if let index = snapshots.firstIndex(where: { $0.id == container.id }) {
                snapshots[index].configuration.labels[DockerLabels.name] = name
            }
        }
    }
}

/// A list held between reading the engine's containers and answering, so that a test can run
/// other routes in that window.
struct ListGate: Sendable {
    private let held: AsyncStream<Void>
    private let heldSignal: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseSignal: AsyncStream<Void>.Continuation

    init() {
        (held, heldSignal) = AsyncStream<Void>.makeStream()
        (released, releaseSignal) = AsyncStream<Void>.makeStream()
    }

    /// The list's side: says it has read the containers, then waits to be let go.
    func hold() async {
        heldSignal.yield()
        for await _ in released { break }
    }

    /// The test's side: returns once the list has read the containers.
    func waitUntilHeld() async {
        for await _ in held { break }
    }

    func release() {
        releaseSignal.yield()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ContainerRoutesTests {
    struct Answer {
        let status: HTTPResponseStatus
        let body: String

        func json() throws -> Any {
            try JSONSerialization.jsonObject(with: Data(body.utf8))
        }

        var message: String? {
            ((try? json()) as? [String: Any])?["message"] as? String
        }
    }

    let engine: FakeEngine
    let identities: DockerIdentityStore
    let router: DockerRouter

    init(snapshots: [ContainerSnapshot], identities: DockerIdentityStore = DockerIdentityStore(persistence: nil)) {
        engine = FakeEngine(snapshots: snapshots)
        self.identities = identities
        var router = DockerRouter()
        ContainerRoutes.register(
            on: &router, engine: engine, identities: identities, streams: DockerContainerStreams(engine: engine), now: { Fixtures.now })
        self.router = router
    }

    init() {
        self.init(snapshots: [])
    }

    func call(_ method: HTTPMethod, _ uri: String, body: String = "", peer: DockerPeer? = nil) async throws -> Answer {
        let request = try DockerRequest(method: method, uri: "/v1.48" + uri, headers: [:], body: ByteBuffer(string: body), peer: peer)
        guard case .data(let status, _, let buffer, _) = await router.respond(to: request) else {
            Issue.record("expected a whole response")
            return Answer(status: .internalServerError, body: "")
        }
        return Answer(status: status, body: String(buffer: buffer))
    }

    func create(_ name: String, image: String = "alpine") async throws -> String {
        let answer = try await call(.POST, "/containers/create?name=\(name)", body: #"{"Image":"\#(image)","Cmd":["sleep","60"]}"#)
        #expect(answer.status == .created)
        return try #require((try answer.json() as? [String: Any])?["Id"] as? String)
    }

    @Test("create answers 201 with the ID and warnings, and the container lists, inspects and resolves by name and short ID")
    func createListInspect() async throws {
        let answer = try await call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine","HostConfig":{"Privileged":true}}"#)
        #expect(answer.status == .created)
        let object = try #require(try answer.json() as? [String: Any])
        let id = try #require(object["Id"] as? String)
        #expect(DockerIdentityTable.isDockerID(id))
        #expect((object["Warnings"] as? [String])?.count == 1)
        #expect(engine.plans.first?.configuration.id == String(id.prefix(12)))

        let listed = try await call(.GET, "/containers/json?all=1")
        let summaries = try #require(try listed.json() as? [[String: Any]])
        #expect(summaries.map { $0["Names"] as? [String] } == [["/web"]])
        #expect(summaries.first?["State"] as? String == "created")
        // Control: a created container is not running, so the default list leaves it out.
        #expect(try await call(.GET, "/containers/json").body == "[]")

        for reference in ["web", "/web", String(id.prefix(12)), id] {
            let inspect = try await call(.GET, "/containers/\(reference)/json")
            #expect(inspect.status == .ok)
            #expect((try inspect.json() as? [String: Any])?["Id"] as? String == id)
        }
    }

    @Test("a missing image is dockerd's 404 so the CLI pulls, and the name stays free")
    func missingImage() async throws {
        let missing = try await call(.POST, "/containers/create?name=cache", body: #"{"Image":"redis"}"#)
        #expect(missing.status == .notFound)
        #expect(missing.message == "No such image: redis:latest")
        let tagged = try await call(.POST, "/containers/create", body: #"{"Image":"ghcr.io/org/app:1.2"}"#)
        #expect(tagged.message == "No such image: ghcr.io/org/app:1.2")
        #expect(engine.plans.isEmpty)
        // Control: once the image is here the same create succeeds, under the same name.
        engine.images["redis"] = Fixtures.image()
        #expect(try await call(.POST, "/containers/create?name=cache", body: #"{"Image":"redis"}"#).status == .created)
    }

    @Test("a taken name is dockerd's 409, and two creates of one name cannot both win")
    func nameConflict() async throws {
        let id = try await create("web")
        let again = try await call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine"}"#)
        #expect(again.status == .conflict)
        #expect(
            again.message
                == "Conflict. The container name \"/web\" is already in use by container \"\(id)\". You have to remove (or rename) that container to be able to reuse that name."
        )
        async let first = call(.POST, "/containers/create?name=api", body: #"{"Image":"alpine"}"#)
        async let second = call(.POST, "/containers/create?name=api", body: #"{"Image":"alpine"}"#)
        let statuses = try await [first.status, second.status].map(\.code).sorted()
        #expect(statuses == [201, 409])
        // Control: an invalid name is a 400, not a conflict.
        #expect(try await call(.POST, "/containers/create?name=-x", body: #"{"Image":"alpine"}"#).status == .badRequest)
    }

    @Test("an unknown container is dockerd's 404, an ambiguous prefix a 400")
    func lookups() async throws {
        let missing = try await call(.GET, "/containers/nope/json")
        #expect(missing.status == .notFound)
        #expect(missing.message == "No such container: nope")
        let routes = ContainerRoutesTests(snapshots: [
            Fixtures.dockerContainer(name: "a", dockerID: Fixtures.id("abc111111111")),
            Fixtures.dockerContainer(name: "b", dockerID: Fixtures.id("abc222222222")),
            Fixtures.snapshot(Fixtures.configuration(id: "legacy")),
        ])
        let ambiguous = try await routes.call(.POST, "/containers/abc/stop")
        #expect(ambiguous.status == .badRequest)
        #expect(ambiguous.message == "multiple IDs found with provided prefix: abc")
        // Control: a longer prefix is unique, and a foreign container answers to its engine ID
        // as its name and to a prefix of its hashed ID.
        #expect(try await routes.call(.GET, "/containers/abc1/json").status == .ok)
        #expect(try await routes.call(.GET, "/containers/legacy/json").status == .ok)
        let hashed = DockerIdentityTable.foreignID(engineID: "legacy")
        #expect((try await routes.call(.GET, "/containers/\(hashed.prefix(10))/json").json() as? [String: Any])?["Name"] as? String == "/legacy")
    }

    @Test("stop answers 304 for a stopped container and start 304 for a running one")
    func notModified() async throws {
        let id = try await create("web")
        #expect(try await call(.POST, "/containers/web/start").status == .noContent)
        #expect(try await call(.POST, "/containers/web/start").status == .notModified)
        #expect(try await call(.POST, "/containers/web/stop?t=3").status == .noContent)
        #expect(try await call(.POST, "/containers/web/stop").status == .notModified)
        let engineID = String(id.prefix(12))
        #expect(engine.calls == ["start \(engineID)", "stop \(engineID) 3 -"])
    }

    @Test("kill signals a running container and refuses a stopped one with dockerd's 409")
    func kill() async throws {
        let id = try await create("web")
        let refused = try await call(.POST, "/containers/web/kill")
        #expect(refused.status == .conflict)
        #expect(refused.message == "cannot kill container: web: container \(id) is not running")
        _ = try await call(.POST, "/containers/web/start")
        #expect(try await call(.POST, "/containers/web/kill?signal=SIGTERM").status == .noContent)
        #expect(engine.calls.last == "kill \(id.prefix(12)) SIGTERM")
        _ = try await call(.POST, "/containers/web/start")
        _ = try await call(.POST, "/containers/web/kill")
        #expect(engine.calls.last == "kill \(id.prefix(12)) KILL")
    }

    @Test("restart stops a running container then starts it, and starts a stopped one")
    func restart() async throws {
        let id = try await create("web")
        let engineID = String(id.prefix(12))
        #expect(try await call(.POST, "/containers/web/restart").status == .noContent)
        #expect(engine.calls == ["start \(engineID)"])
        #expect(try await call(.POST, "/containers/web/restart?t=1").status == .noContent)
        #expect(engine.calls == ["start \(engineID)", "stop \(engineID) 1 -", "start \(engineID)"])
        #expect(engine.snapshot(engineID)?.status == .running)
    }

    @Test("delete refuses a running container without force, removes it with force, and v removes its anonymous volumes")
    func delete() async throws {
        let created = try await call(.POST, "/containers/create?name=web", body: #"{"Image":"alpine","Volumes":{"/data":{}}}"#)
        #expect(created.status == .created)
        let anonymous = try #require(engine.plans.first?.extras.anonymousVolumes.first)
        _ = try await call(.POST, "/containers/web/start")
        let refused = try await call(.DELETE, "/containers/web")
        #expect(refused.status == .conflict)
        #expect(refused.message == "cannot remove container \"web\": container is running: stop the container before removing or force remove")
        #expect(try await call(.DELETE, "/containers/web?force=1&v=1").status == .noContent)
        #expect(engine.calls.suffix(2) == ["delete \(engine.plans[0].configuration.id) true", "volume rm \(anonymous)"])
        #expect(try await call(.GET, "/containers/web/json").status == .notFound)
        // Control: without v the volumes stay.
        _ = try await create("db")
        #expect(try await call(.DELETE, "/containers/db").status == .noContent)
        #expect(!(engine.calls.last ?? "").hasPrefix("volume rm"))
    }

    @Test("containers made while a list was being taken keep their extras when that list is joined: --rm and rm -v behave")
    func listTakenBeforeCreate() async throws {
        let gate = ListGate()
        engine.listGate = gate
        // `docker ps` reads the engine's containers before either create, and answers after both.
        async let stale = call(.GET, "/containers/json?all=1")
        await gate.waitUntilHeld()
        let made = try await call(.POST, "/containers/create?name=once", body: #"{"Image":"alpine","HostConfig":{"AutoRemove":true}}"#)
        #expect(made.status == .created)
        let kept = try await call(.POST, "/containers/create?name=data", body: #"{"Image":"alpine","Volumes":{"/data":{}}}"#)
        #expect(kept.status == .created)
        gate.release()
        #expect(try await stale.body == "[]")

        let records = await identities.records
        #expect(Set(records.map(\.name)) == ["once", "data"])
        #expect(records.allSatisfy { $0.extras != nil })
        let inspect = try #require(try await call(.GET, "/containers/once/json").json() as? [String: Any])
        #expect((inspect["HostConfig"] as? [String: Any])?["AutoRemove"] as? Bool == true)

        // --rm: a start that fails removes the container, as dockerd does.
        let once = try #require(engine.plans.first?.configuration.id)
        engine.bootstrapError = DockerAPIError.internalError("no VM")
        #expect(try await call(.POST, "/containers/once/start").status == .internalServerError)
        #expect(engine.calls.contains("delete \(once) true"))
        #expect(engine.snapshot(once) == nil)

        // rm -v: the volume the create made for the container goes with it.
        let anonymous = try #require(engine.plans.last?.extras.anonymousVolumes.first)
        #expect(try await call(.DELETE, "/containers/data?v=1").status == .noContent)
        #expect(engine.calls.last == "volume rm \(anonymous)")

        // Control: a container deleted behind this service's back loses its record at the
        // next list, made after the delete.
        _ = try await create("gone")
        let gone = try #require(engine.plans.last?.configuration.id)
        try await engine.delete(try #require(engine.snapshot(gone)), force: true)
        #expect(await identities.records.map(\.name) == ["gone"])
        #expect(try await call(.GET, "/containers/json?all=1").body == "[]")
        #expect(await identities.records.isEmpty)
    }

    @Test("rename takes a free name, refuses a taken one, and the old name stops resolving")
    func rename() async throws {
        _ = try await create("web")
        let db = try await create("db")
        #expect(try await call(.POST, "/containers/web/rename?name=front").status == .noContent)
        #expect(try await call(.GET, "/containers/front/json").status == .ok)
        #expect(try await call(.GET, "/containers/web/json").status == .notFound)
        let taken = try await call(.POST, "/containers/front/rename?name=db")
        #expect(taken.status == .conflict)
        #expect(taken.message?.contains("is already in use by container \"\(db)\"") == true)
        #expect(try await call(.POST, "/containers/front/rename").status == .badRequest)
    }

    @Test("prune deletes stopped containers, honours label filters, and leaves running ones")
    func prune() async throws {
        let job = try await create("job")
        _ = try await create("web")
        _ = try await call(.POST, "/containers/web/start")
        let kept = try await call(.POST, "/containers/create?name=keep", body: #"{"Image":"alpine","Labels":{"keep":"yes"}}"#)
        #expect(kept.status == .created)
        let pruned = try await call(.POST, "/containers/prune?filters=%7B%22label!%22%3A%5B%22keep%22%5D%7D")
        #expect(pruned.status == .ok)
        let object = try #require(try pruned.json() as? [String: Any])
        #expect(object["ContainersDeleted"] as? [String] == [job])
        #expect(object["SpaceReclaimed"] as? Int == 0)
        let names = try #require(try await call(.GET, "/containers/json?all=1").json() as? [[String: Any]]).compactMap { ($0["Names"] as? [String])?.first }
        #expect(names.sorted() == ["/keep", "/web"])
        #expect(try await call(.POST, "/containers/prune?filters=%7B%22until%22%3A%5B%2210m%22%5D%7D").status == .badRequest)
        // Control: nothing left to prune reports none.
        let none = try #require(try await call(.POST, "/containers/prune?filters=%7B%22label%22%3A%5B%22nothing%22%5D%7D").json() as? [String: Any])
        #expect(none["ContainersDeleted"] == nil)
    }

    @Test("pause, unpause, update and commit answer 501")
    func notImplemented() async throws {
        _ = try await create("web")
        for action in ["pause", "unpause", "update"] {
            let answer = try await call(.POST, "/containers/web/\(action)")
            #expect(answer.status == .notImplemented)
            #expect(answer.message?.hasPrefix("\(action) is not supported") == true)
        }
        #expect(try await call(.POST, "/commit?container=web").status == .notImplemented)
        // Control: the container itself is fine, and commit is only a POST.
        #expect(try await call(.GET, "/containers/web/json").status == .ok)
        #expect(try await call(.GET, "/commit").status == .notFound)
    }

    @Test("list filters and refuses a filter it does not know")
    func listFilters() async throws {
        _ = try await create("web")
        _ = try await create("db")
        _ = try await call(.POST, "/containers/web/start")
        let running = try #require(try await call(.GET, "/containers/json").json() as? [[String: Any]])
        #expect(running.compactMap { ($0["Names"] as? [String])?.first } == ["/web"])
        let named = try #require(
            try await call(.GET, "/containers/json?all=1&filters=%7B%22name%22%3A%7B%22db%22%3Atrue%7D%7D").json() as? [[String: Any]])
        #expect(named.compactMap { ($0["Names"] as? [String])?.first } == ["/db"])
        #expect(try await call(.GET, "/containers/json?filters=%7B%22colour%22%3A%5B%22x%22%5D%7D").status == .badRequest)
    }
}
