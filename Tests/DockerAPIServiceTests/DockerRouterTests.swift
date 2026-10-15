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

import NIOCore
import NIOHTTP1
import Testing

@testable import DockerAPIService

struct DockerRouterTests {
    private func request(_ uri: String, method: HTTPMethod = .GET) throws -> DockerRequest {
        try DockerRequest(method: method, uri: uri, headers: [:], body: ByteBuffer())
    }

    private func body(_ response: DockerResponse) -> (HTTPResponseStatus, String)? {
        guard case .data(let status, _, let body, _) = response else { return nil }
        return (status, String(buffer: body))
    }

    @Test("a versioned path is served at its version, and a bare one at the current version")
    func versions() throws {
        #expect(try request("/v1.44/containers/json").apiVersion == DockerAPIVersion(major: 1, minor: 44))
        #expect(try request("/v1.48/containers/json").segments == ["containers", "json"])
        #expect(try request("/containers/json").apiVersion == .current)
    }

    @Test("versions outside what is implemented are refused with dockerd's words")
    func versionLimits() throws {
        #expect(throws: DockerAPIError.badRequest("client version 1.30 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version")) {
            try request("/v1.30/_ping")
        }
        #expect(throws: DockerAPIError.badRequest("client version 1.49 is too new. Maximum supported API version is 1.48")) {
            try request("/v1.49/_ping")
        }
        // A first segment that only looks like a version is a path.
        #expect(try request("/volumes/v1").segments == ["volumes", "v1"])
    }

    @Test("an image reference with slashes is one parameter")
    func greedyParameter() async throws {
        var router = DockerRouter()
        router.add(.GET, "/images/{name+}/json") { _, parameters in .text(try parameters["name"]) }
        router.add(.DELETE, "/images/{name+}") { _, parameters in .text("delete " + (try parameters["name"])) }
        #expect(body(await router.respond(to: try request("/v1.48/images/ghcr.io/org/app:1.2/json")))?.1 == "ghcr.io/org/app:1.2")
        #expect(body(await router.respond(to: try request("/images/alpine/json")))?.1 == "alpine")
        #expect(body(await router.respond(to: try request("/images/docker.io/library/alpine:3.22", method: .DELETE)))?.1 == "delete docker.io/library/alpine:3.22")
        // Control: a greedy parameter needs at least one segment.
        #expect(body(await router.respond(to: try request("/images/json")))?.0 == .notFound)
    }

    @Test("a literal route wins over a parameter in the same place, whatever the order added")
    func literalsFirst() async throws {
        var router = DockerRouter()
        router.add(.GET, "/containers/{id}") { _, parameters in .text("container " + (try parameters["id"])) }
        router.add(.GET, "/containers/json") { _, _ in .text("list") }
        #expect(body(await router.respond(to: try request("/containers/json")))?.1 == "list")
        #expect(body(await router.respond(to: try request("/containers/abc")))?.1 == "container abc")
    }

    @Test("HEAD is answered by the GET route, and an unknown path is dockerd's 404")
    func headAndNotFound() async throws {
        var router = DockerRouter()
        router.add(.GET, "/_ping") { _, _ in .text("OK") }
        #expect(body(await router.respond(to: try request("/_ping", method: .HEAD)))?.1 == "OK")
        let missing = body(await router.respond(to: try request("/nope", method: .GET)))
        #expect(missing?.0 == .notFound)
        #expect(missing?.1 == #"{"message":"page not found"}"#)
        // Control: the right path with the wrong method is not served.
        #expect(body(await router.respond(to: try request("/_ping", method: .POST)))?.0 == .notFound)
    }

    @Test("a route's error is the client's error body")
    func errors() async throws {
        var router = DockerRouter()
        router.add(.GET, "/containers/{id}/json") { _, parameters in throw DockerAPIError.notFound("No such container: \(try parameters["id"])") }
        let answered = body(await router.respond(to: try request("/containers/web/json")))
        #expect(answered?.0 == .notFound)
        #expect(answered?.1 == #"{"message":"No such container: web"}"#)
    }

    @Test("queries decode as Go encodes them, and filters come in both of the CLI's shapes")
    func queries() throws {
        let plain = try request("/containers/json?all=1&name=a+b&label=x%3Dy&label=z")
        #expect(try plain.bool("all"))
        #expect(plain.query("name") == "a b")
        #expect(plain.query["label"] == ["x=y", "z"])
        #expect(try !plain.bool("size"))
        #expect(throws: DockerAPIError.self) { try request("/x?all=maybe").bool("all") }

        let current = try request("/containers/json?filters=%7B%22label%22%3A%7B%22a%3Db%22%3Atrue%2C%22c%22%3Afalse%7D%7D")
        #expect(try current.filters() == ["label": ["a=b"]])
        let older = try request("/containers/json?filters=%7B%22status%22%3A%5B%22running%22%5D%7D")
        #expect(try older.filters() == ["status": ["running"]])
        #expect(throws: DockerAPIError.self) { try request("/containers/json?filters=nope").filters() }
    }
}
