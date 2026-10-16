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

struct ContainerListFilterTests {
    let context = DockerViewContext(now: Fixtures.now, builtinNetwork: Fixtures.builtin)

    /// web (running, newest), db (running, on `shop`, with a volume), job (exited 3), fresh (created, oldest).
    var containers: [DockerContainer] {
        var web = Fixtures.configuration(id: "aaa111", labels: ["app": "shop", "tier": "front"], created: Fixtures.now.addingTimeInterval(-10))
        web.image = Fixtures.imageDescription("docker.io/library/nginx:latest")
        var db = Fixtures.configuration(id: "bbb222", labels: ["app": "shop"], created: Fixtures.now.addingTimeInterval(-20))
        db.networks = [AttachmentConfiguration(network: "shop_net", options: AttachmentOptions(hostname: "db"))]
        db.mounts = [.volume(name: "pgdata", format: "ext4", source: "/v/pgdata", destination: "/var/lib/postgresql", options: [])]
        let job = Fixtures.configuration(id: "ccc333", created: Fixtures.now.addingTimeInterval(-30))
        let fresh = Fixtures.configuration(id: "ddd444", created: Fixtures.now.addingTimeInterval(-40))
        return [
            DockerContainer(snapshot: Fixtures.snapshot(fresh, status: .stopped, started: nil), dockerID: Fixtures.id("ddd444"), name: "fresh"),
            DockerContainer(snapshot: Fixtures.snapshot(web), dockerID: Fixtures.id("aaa111"), name: "web"),
            DockerContainer(snapshot: Fixtures.snapshot(job, status: .stopped, exitCode: 3), dockerID: Fixtures.id("ccc333"), name: "job"),
            DockerContainer(snapshot: Fixtures.snapshot(db), dockerID: Fixtures.id("bbb222"), name: "db"),
        ]
    }

    private func names(_ filters: [String: [String]], all: Bool = true, limit: Int? = nil) throws -> [String] {
        try ContainerListFilter(filters: filters, all: all, limit: limit, context: context).apply(containers).map(\.name)
    }

    @Test("running only by default, newest first; all lists every container")
    func allAndDefault() throws {
        #expect(try names([:], all: false) == ["web", "db"])
        #expect(try names([:]) == ["web", "db", "job", "fresh"])
    }

    @Test("limit lists the newest n of every state, without all")
    func limit() throws {
        #expect(try names([:], all: false, limit: 3) == ["web", "db", "job"])
        // Control: no limit keeps the running-only default.
        #expect(try names([:], all: false, limit: 0) == ["web", "db"])
    }

    @Test("id is a pattern found in the full ID, so a prefix matches")
    func id() throws {
        #expect(try names(["id": ["aaa1"]]) == ["web"])
        #expect(try names(["id": ["aaa1", "ccc"]]) == ["web", "job"])
        #expect(try names(["id": ["zzz"]]) == [])
    }

    @Test("name matches with or without the slash, as a pattern")
    func name() throws {
        #expect(try names(["name": ["/web"]]) == ["web"])
        #expect(try names(["name": ["^d"]]) == ["db"])
        #expect(try names(["name": ["e"]]) == ["web", "fresh"])
        #expect(try names(["name": ["nope"]]) == [])
    }

    @Test("label is a key or key=value, and every one must hold")
    func label() throws {
        #expect(try names(["label": ["app"]]) == ["web", "db"])
        #expect(try names(["label": ["app=shop", "tier=front"]]) == ["web"])
        #expect(try names(["label": ["app=other"]]) == [])
    }

    @Test("status lists stopped containers without all, and an unknown status is refused")
    func status() throws {
        #expect(try names(["status": ["exited"]], all: false) == ["job"])
        #expect(try names(["status": ["created", "exited"]], all: false) == ["job", "fresh"])
        #expect(throws: DockerAPIError.self) { try names(["status": ["sleeping"]]) }
    }

    @Test("exited matches the code of a container that ran and stopped")
    func exited() throws {
        #expect(try names(["exited": ["3"]]) == ["job"])
        #expect(try names(["exited": ["0"]]) == [])
        #expect(throws: DockerAPIError.badRequest("invalid filter 'exited=x'")) { try names(["exited": ["x"]]) }
    }

    @Test("ancestor matches the image by name, with or without its tag, or by ID")
    func ancestor() throws {
        #expect(try names(["ancestor": ["nginx"]]) == ["web"])
        #expect(try names(["ancestor": ["nginx:latest"]]) == ["web"])
        #expect(try names(["ancestor": ["docker.io/library/alpine:latest"]]) == ["db", "job", "fresh"])
        #expect(try names(["ancestor": [String(Fixtures.imageDescription().digest.dropFirst(7).prefix(12))]]).count == 4)
        #expect(try names(["ancestor": ["redis"]]) == [])
    }

    @Test("network matches the Docker name, bridge being the default network")
    func network() throws {
        #expect(try names(["network": ["shop_net"]]) == ["db"])
        #expect(try names(["network": ["bridge"]]) == ["web", "job", "fresh"])
        #expect(try names(["network": ["host"]]) == [])
    }

    @Test("volume matches a volume's name or a mount's destination")
    func volume() throws {
        #expect(try names(["volume": ["pgdata"]]) == ["db"])
        #expect(try names(["volume": ["/var/lib/postgresql"]]) == ["db"])
        #expect(try names(["volume": ["other"]]) == [])
    }

    @Test("an unknown filter is refused, and one dockerd has but this does not is refused by name")
    func unknownFilters() {
        #expect(throws: DockerAPIError.badRequest("invalid filter 'colour'")) { try names(["colour": ["red"]]) }
        #expect(throws: DockerAPIError.badRequest("the 'since' filter is not supported")) { try names(["since": ["web"]]) }
    }
}
