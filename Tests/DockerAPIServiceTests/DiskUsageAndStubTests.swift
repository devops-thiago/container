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

/// `GET /system/df`, and the routes this service answers only to say it does not serve them.
struct DiskUsageAndStubTests {
    typealias F = StoreFixtures

    /// The engine's sizes: the images' total, and each container's directory.
    struct FakeDisk: EngineDiskUsage {
        var sizes: [String: Int64]

        func layersSize() async throws -> Int64 { 123_456 }

        func containerSize(_ engineID: String) async throws -> Int64? {
            guard let size = sizes[engineID] else { throw DockerAPIError.notFound("no \(engineID)") }
            return size
        }
    }

    let router: DockerRouter

    init() {
        let images = FakeImageStore(ImageCatalogTests.catalog.images.flatMap(\.records) + [ImageCatalogTests.vminit])
        let engine = FakeEngine(snapshots: [
            F.container("web", image: ImageCatalogTests.alpine, run: .running),
            F.container("job", image: ImageCatalogTests.alpine, run: .exited),
            F.container("cache", image: ImageCatalogTests.redis),
        ])
        let volumes = FakeVolumes([FakeVolumes.volume("data"), FakeVolumes.volume("logs")])
        var router = DockerRouter()
        DiskUsageRoutes.register(
            on: &router, disk: FakeDisk(sizes: ["web": 4096, "cache": 0]), images: images, containers: engine, volumes: volumes,
            identities: DockerIdentityStore(persistence: nil), now: { Fixtures.now })
        UnsupportedRoutes.register(on: &router)
        self.router = router
    }

    func call(_ method: HTTPMethod, _ uri: String) async throws -> (HTTPResponseStatus, String) {
        guard case .data(let status, _, let body, _) = await router.respond(to: try DockerRequest(method: method, uri: uri, headers: [:], body: ByteBuffer()))
        else {
            Issue.record("expected a whole response")
            return (.internalServerError, "")
        }
        return (status, String(buffer: body))
    }

    func json(_ uri: String) async throws -> [String: Any] {
        let (status, body) = try await call(.GET, uri)
        #expect(status == .ok)
        return try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    @Test("df reports the images with the containers using each, the containers with their size, and the volumes with their usage")
    func everything() async throws {
        let usage = try await json("/v1.48/system/df")
        #expect(usage["LayersSize"] as? Int == 123_456)
        #expect((usage["BuildCache"] as? [Any])?.isEmpty == true)

        let images = try #require(usage["Images"] as? [[String: Any]])
        // The engine's own images are not listed, as `docker images` leaves them out.
        #expect(!images.contains { $0["Id"] as? String == F.digest("f") })
        let alpine = try #require(images.first { $0["Id"] as? String == F.digest("a") })
        #expect(alpine["Containers"] as? Int == 2)
        #expect(alpine["SharedSize"] as? Int == -1)
        #expect(alpine["Size"] as? Int == 4_000_000)
        #expect(images.first { $0["Id"] as? String == F.digest("b") }?["Containers"] as? Int == 1)
        #expect(images.first { $0["Id"] as? String == F.digest("c") }?["Containers"] as? Int == 0)

        let containers = try #require(usage["Containers"] as? [[String: Any]])
        #expect(containers.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: containers.map { (($0["Names"] as? [String])?.first ?? "", $0) })
        #expect(byName["/web"]?["SizeRw"] as? Int == 4096)
        #expect(byName["/cache"]?["SizeRw"] as? Int == 0)
        // Control: a size the engine cannot give is left out, not made up.
        #expect(byName["/job"]?["SizeRw"] == nil)
        #expect(byName["/web"]?["State"] as? String == "running")

        let volumes = try #require(usage["Volumes"] as? [[String: Any]])
        #expect(volumes.map { $0["Name"] as? String } == ["data", "logs"])
        let data = try #require(volumes.first?["UsageData"] as? [String: Any])
        #expect(data["Size"] as? Int == 1000)
        #expect(data["RefCount"] as? Int == 0)
    }

    @Test("df reports only the kinds asked for, and refuses one it does not know in dockerd's words")
    func types() async throws {
        let volumes = try await json("/v1.48/system/df?type=volume")
        #expect(volumes["Volumes"] != nil)
        #expect(volumes["Images"] == nil)
        #expect(volumes["Containers"] == nil)
        #expect(volumes["BuildCache"] == nil)
        let two = try await json("/v1.48/system/df?type=container&type=build-cache")
        #expect(two["Containers"] != nil)
        #expect(two["BuildCache"] != nil)
        #expect(two["Volumes"] == nil)

        let (status, body) = try await call(.GET, "/v1.48/system/df?type=layers")
        #expect(status == .badRequest)
        #expect(body == #"{"message":"unknown object type: layers"}"#)
    }

    @Test("a volume's reference count is the containers that mount it, running or not")
    func refCount() async throws {
        var configuration = Fixtures.configuration(id: "web")
        configuration.mounts = [.volume(name: "data", format: "ext4", source: "/volumes/data/volume.img", destination: "/data", options: [])]
        let engine = FakeEngine(snapshots: [Fixtures.snapshot(configuration, status: .stopped, started: nil)])
        var router = DockerRouter()
        DiskUsageRoutes.register(
            on: &router, disk: FakeDisk(sizes: [:]), images: FakeImageStore(), containers: engine,
            volumes: FakeVolumes([FakeVolumes.volume("data"), FakeVolumes.volume("logs")]), identities: DockerIdentityStore(persistence: nil))
        guard case .data(_, _, let body, _) = await router.respond(to: try DockerRequest(method: .GET, uri: "/system/df?type=volume", headers: [:], body: ByteBuffer()))
        else { return }
        let usage = try #require(try JSONSerialization.jsonObject(with: Data(String(buffer: body).utf8)) as? [String: Any])
        let volumes = try #require(usage["Volumes"] as? [[String: Any]])
        #expect(volumes.map { ($0["UsageData"] as? [String: Any])?["RefCount"] as? Int } == [1, 0])
    }

    @Test(
        "what this service does not serve is answered in words: swarm as dockerd on a node in none, the rest as 501",
        arguments: [
            (HTTPMethod.GET, "/v1.48/swarm", HTTPResponseStatus.serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.POST, "/v1.48/swarm/update", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/swarm/unlockkey", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.POST, "/v1.48/swarm/leave", .serviceUnavailable, UnsupportedRoutes.notInASwarm),
            (.POST, "/v1.48/swarm/init", .notImplemented, "swarm mode is not supported by SiliconShip"),
            (.POST, "/v1.48/swarm/join", .notImplemented, "swarm mode is not supported by SiliconShip"),
            (.GET, "/v1.48/services", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.POST, "/v1.48/services/create", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/services/web/logs", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.DELETE, "/v1.48/services/web", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/nodes", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/secrets", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.POST, "/v1.48/configs/create", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/tasks", .serviceUnavailable, UnsupportedRoutes.notASwarmManager),
            (.GET, "/v1.48/plugins", .notImplemented, "plugins are not supported by SiliconShip"),
            (.POST, "/v1.48/plugins/pull", .notImplemented, "plugins are not supported by SiliconShip"),
        ])
    func unsupported(method: HTTPMethod, path: String, status: HTTPResponseStatus, message: String) async throws {
        let (answered, body) = try await call(method, path)
        #expect(answered == status)
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String]
        #expect(decoded?["message"] == message)
    }

    @Test("changes, export and build are 501s that say why")
    func notImplemented() async throws {
        let changes = try await call(.GET, "/v1.48/containers/web/changes")
        #expect(changes.0 == .notImplemented)
        #expect(changes.1.contains("changes is not supported by SiliconShip"))
        let export = try await call(.GET, "/v1.48/containers/web/export")
        #expect(export.0 == .notImplemented)
        #expect(export.1.contains("docker cp"))
        let build = try await call(.POST, "/v1.48/build?t=web")
        #expect(build.0 == .notImplemented)
        #expect(build.1.contains("DOCKER_BUILDKIT=0"))
        #expect(build.1.contains("#231"))
        // Control: a path nobody serves is still dockerd's 404, and HEAD reaches a GET stub.
        #expect(try await call(.GET, "/v1.48/nothing/here") == (.notFound, #"{"message":"page not found"}"#))
        #expect(try await call(.HEAD, "/v1.48/swarm").0 == .serviceUnavailable)
    }
}
