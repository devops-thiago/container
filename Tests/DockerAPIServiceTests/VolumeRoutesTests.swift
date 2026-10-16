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

/// The volume mapper, its filters and prune selection, and the routes over a fake.
struct VolumeRoutesTests {
    let volumes: FakeVolumes
    let engine: FakeEngine
    let identities = DockerIdentityStore(persistence: nil)
    let router: DockerRouter

    static let named = FakeVolumes.volume("m229-data", labels: ["m229": "1"])
    static let other = FakeVolumes.volume("pgdata", labels: ["app": "db"])
    static let anonymous = FakeVolumes.volume(String(repeating: "f", count: 64), anonymous: true)
    static let mineAnonymous = FakeVolumes.volume(String(repeating: "e", count: 64), labels: ["m229": "1"], anonymous: true)

    /// A container that mounts `volume`.
    static func mounting(_ name: String, _ volume: String, running: Bool = false) -> ContainerSnapshot {
        var configuration = Fixtures.configuration(id: name)
        configuration.mounts = [.volume(name: volume, format: "ext4", source: "/volumes/\(volume)/volume.img", destination: "/data", options: [])]
        return Fixtures.snapshot(configuration, status: running ? .running : .stopped, started: running ? Fixtures.now : nil)
    }

    init(_ volumes: [VolumeConfiguration] = [named, other, anonymous, mineAnonymous], containers: [ContainerSnapshot] = []) {
        self.volumes = FakeVolumes(volumes)
        engine = FakeEngine(snapshots: containers)
        var router = DockerRouter()
        VolumeRoutes.register(on: &router, engine: self.volumes, containers: engine, identities: identities)
        self.router = router
    }

    func call(_ method: HTTPMethod, _ uri: String, body: String = "") async throws -> ContainerRoutesTests.Answer {
        let request = try DockerRequest(method: method, uri: "/v1.48" + uri, headers: [:], body: ByteBuffer(string: body))
        guard case .data(let status, _, let buffer, _) = await router.respond(to: request) else {
            Issue.record("expected a whole response")
            return .init(status: .internalServerError, body: "")
        }
        return .init(status: status, body: String(buffer: buffer))
    }

    @Test("a volume shows as local, with Docker's anonymous label for the engine's")
    func mapper() {
        let shown = VolumeMapper.volume(Self.anonymous)
        #expect(shown.Driver == "local" && shown.Scope == "local")
        #expect(shown.Labels == [VolumeMapper.dockerAnonymousLabel: ""])
        #expect(shown.CreatedAt == "2023-11-14T22:13:20Z")
        #expect(shown.Mountpoint == "/volumes/\(Self.anonymous.name)/volume.img")
        // Control: a named volume's labels are its own.
        #expect(VolumeMapper.volume(Self.named).Labels == ["m229": "1"])
    }

    @Test("a create maps the driver, size and labels, and a create without a name is anonymous")
    func createRequest() throws {
        func body(_ json: String) throws -> DockerVolumeCreateBody {
            try JSONDecoder().decode(DockerVolumeCreateBody.self, from: Data(json.utf8))
        }
        let sized = try VolumeMapper.createRequest(try body(#"{"Name":"m229-v","Driver":"local","DriverOpts":{"size":"1G"},"Labels":{"a":"b"}}"#)) { "x" }
        #expect(sized.name == "m229-v" && sized.driverOpts == ["size": "1G"] && sized.labels == ["a": "b"])
        let anonymous = try VolumeMapper.createRequest(try body("{}")) { "generated" }
        #expect(anonymous.name == "generated")
        #expect(anonymous.labels == [VolumeConfiguration.anonymousLabel: ""])
        let marked = try VolumeMapper.createRequest(try body(#"{"Name":"vv","Labels":{"com.docker.volume.anonymous":""}}"#)) { "x" }
        #expect(marked.labels == [VolumeConfiguration.anonymousLabel: ""])

        #expect(throws: DockerAPIError.notFound(#"create vv: error looking up volume plugin nfs: plugin "nfs" not found"#)) {
            try VolumeMapper.createRequest(try body(#"{"Name":"vv","Driver":"nfs"}"#)) { "x" }
        }
        #expect(throws: DockerAPIError.self) { try VolumeMapper.createRequest(try body(#"{"Name":"v"}"#)) { "x" } }
        #expect(throws: DockerAPIError.self) { try VolumeMapper.createRequest(try body(#"{"Name":"/host/path"}"#)) { "x" } }
        #expect(throws: DockerAPIError.self) { try VolumeMapper.createRequest(try body(#"{"Name":"vv","DriverOpts":{"device":"/dev/disk2"}}"#)) { "x" } }
        #expect(throws: DockerAPIError.self) {
            try VolumeMapper.createRequest(try body(#"{"Name":"vv","Labels":{"com.apple.container.resource.anonymous":""}}"#)) { "x" }
        }
    }

    func users(_ containers: [ContainerSnapshot]) -> [String: [String]] {
        VolumeMapper.users(DockerIdentityTable().joined(containers))
    }

    @Test("the list filters: name as a pattern, label, driver, dangling")
    func listFilters() throws {
        let all = [Self.named, Self.other, Self.anonymous, Self.mineAnonymous]
        let users = users([Self.mounting("c1", "pgdata")])
        func names(_ filters: [String: [String]]) throws -> [String] {
            try VolumeMapper.list(all, filters: filters, users: users).map { String($0.name.prefix(9)) }
        }
        #expect(try names([:]) == ["eeeeeeeee", "fffffffff", "m229-data", "pgdata"])
        #expect(try names(["name": ["m229"]]) == ["m229-data"])
        #expect(try names(["name": ["^pg"]]) == ["pgdata"])
        #expect(try names(["label": ["m229=1"]]) == ["eeeeeeeee", "m229-data"])
        #expect(try names(["label": ["com.docker.volume.anonymous"]]) == ["eeeeeeeee", "fffffffff"])
        #expect(try names(["dangling": ["true"]]) == ["eeeeeeeee", "fffffffff", "m229-data"])
        #expect(try names(["dangling": ["0"]]) == ["pgdata"])
        #expect(try names(["driver": ["local"]]).count == 4)
        #expect(try names(["driver": ["nfs"]]) == [])
        #expect(throws: DockerAPIError.badRequest("invalid filter 'size'")) { try names(["size": ["1"]]) }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'dangling=[maybe]'")) { try names(["dangling": ["maybe"]]) }
    }

    @Test("a prune takes unused anonymous volumes, named ones only with all=true, by label")
    func pruneSelection() throws {
        let all = [Self.named, Self.other, Self.anonymous, Self.mineAnonymous]
        let users = users([Self.mounting("c1", String(repeating: "f", count: 64))])
        func names(_ filters: [String: [String]]) throws -> [String] {
            try VolumeMapper.pruneSelection(all, filters: filters, users: users).map { String($0.name.prefix(9)) }
        }
        // The anonymous volume a stopped container mounts is kept.
        #expect(try names([:]) == ["eeeeeeeee"])
        #expect(try names(["all": ["true"]]) == ["eeeeeeeee", "m229-data", "pgdata"])
        #expect(try names(["all": ["1"], "label": ["m229=1"]]) == ["eeeeeeeee", "m229-data"])
        #expect(try names(["all": ["true"], "label!": ["app"]]) == ["eeeeeeeee", "m229-data"])
        // Control: all=false is the default, and an unmatched label picks nothing.
        #expect(try names(["all": ["false"]]) == ["eeeeeeeee"])
        #expect(try names(["all": ["true"], "label": ["m229=2"]]) == [])
        #expect(throws: DockerAPIError.badRequest(#"invalid filter 'all': strconv.ParseBool: parsing "yes": invalid syntax"#)) {
            try names(["all": ["yes"]])
        }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'all=[true false]': only one value is expected")) { try names(["all": ["true", "false"]]) }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'dangling'")) { try names(["dangling": ["true"]]) }
    }

    @Test("create, inspect, list and delete over the routes, with dockerd's 404 and 409")
    func routes() async throws {
        let routes = VolumeRoutesTests(containers: [Self.mounting("c1", "pgdata")])
        let created = try await routes.call(.POST, "/volumes/create", body: #"{"Name":"m229-new","Labels":{"m229":"1"},"DriverOpts":{"size":"64M"}}"#)
        #expect(created.status == .created)
        #expect((try created.json() as? [String: Any])?["Options"] as? [String: String] == ["size": "64M"])
        // A name that exists answers with that volume.
        let again = try await routes.call(.POST, "/volumes/create", body: #"{"Name":"m229-new"}"#)
        #expect(again.status == .created)
        #expect(routes.volumes.calls == ["create m229-new"])

        let inspect = try await routes.call(.GET, "/volumes/m229-new")
        #expect((try inspect.json() as? [String: Any])?["Labels"] as? [String: String] == ["m229": "1"])
        let missing = try await routes.call(.GET, "/volumes/nope")
        #expect(missing.status == .notFound && missing.message == "get nope: no such volume")
        let list = try #require(try await routes.call(.GET, "/volumes?filters=%7B%22label%22%3A%5B%22m229%3D1%22%5D%7D").json() as? [String: Any])
        #expect((list["Volumes"] as? [[String: Any]])?.compactMap { $0["Name"] as? String } == [String(repeating: "e", count: 64), "m229-data", "m229-new"])
        #expect(list["Warnings"] as? [String] == [])

        let inUse = try await routes.call(.DELETE, "/volumes/pgdata?force=1")
        #expect(inUse.status == .conflict)
        #expect(inUse.message == "remove pgdata: volume is in use - [\(DockerIdentityTable.foreignID(engineID: "c1"))]")
        #expect(try await routes.call(.DELETE, "/volumes/nope").status == .notFound)
        // Control: forced, a missing volume is not an error, and a free one goes.
        #expect(try await routes.call(.DELETE, "/volumes/nope?force=1").status == .noContent)
        #expect(try await routes.call(.DELETE, "/volumes/m229-new").status == .noContent)
        #expect(!routes.volumes.names.contains("m229-new"))
        #expect(routes.volumes.names.contains("pgdata"))
    }

    @Test("a prune over the routes hands the key=value labels to the engine too, and reports what went")
    func prune() async throws {
        let routes = VolumeRoutesTests()
        let report = try #require(
            try await routes.call(.POST, "/volumes/prune?filters=%7B%22label%22%3A%5B%22m229%3D1%22%5D%2C%22all%22%3A%5B%22true%22%5D%7D").json() as? [String: Any])
        #expect(report["VolumesDeleted"] as? [String] == [String(repeating: "e", count: 64), "m229-data"])
        #expect(report["SpaceReclaimed"] as? Int == 2000)
        #expect(routes.volumes.calls.allSatisfy { $0.hasSuffix(" m229=1") })
        #expect(routes.volumes.names == ["pgdata", String(repeating: "f", count: 64)].sorted())
        let empty = try #require(try await routes.call(.POST, "/volumes/prune?filters=%7B%22label%22%3A%5B%22m229%3D1%22%5D%7D").json() as? [String: Any])
        #expect(empty["VolumesDeleted"] as? [String] == [])
    }
}

extension DockerIdentityTable {
    /// The containers as the routes see them, without a store.
    func joined(_ snapshots: [ContainerSnapshot]) -> [DockerContainer] {
        var table = self
        return table.join(snapshots)
    }
}
