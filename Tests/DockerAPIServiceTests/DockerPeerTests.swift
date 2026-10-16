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
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import DockerAPIService

/// Who sent a request: read from the socket when the connection is accepted, put on every
/// request it carries, and handed to the engine on each call that can ask for a folder, so the
/// engine's panel names the Docker client rather than this agent.
@Suite(.timeLimit(.minutes(1)))
struct DockerPeerTests {
    static let docker = DockerPeer(pid: 4242, name: "docker")

    /// What this test process is called on the other end of a socket it connects.
    static var ownRequester: String {
        get throws { try #require(DockerPeer.resolve(pid: getpid())).requester }
    }

    @Test("a peer is named by its process name and pid, or by its pid alone")
    func describing() {
        #expect(Self.docker.requester == "docker (pid 4242)")
        #expect(DockerPeer(pid: 7, name: nil).requester == "pid 7")
        #expect(DockerPeer(pid: 7, name: "java\n\u{1B}[31m").requester == "java[31m (pid 7)")
        // A name that is nothing but control characters is no name.
        #expect(DockerPeer(pid: 7, name: "\u{202E}\u{7}").requester == "pid 7")
        let long = DockerPeer(pid: 99, name: String(repeating: "x", count: 200)).requester
        #expect(long.count <= GrantRequester.maxLength)
        #expect(long.hasSuffix(" (pid 99)"))
        // Control: a name that fits is kept whole.
        #expect(DockerPeer(pid: 1, name: "com.docker.cli").requester == "com.docker.cli (pid 1)")
    }

    @Test("resolving reads the process's name, and no process is no peer")
    func resolving() throws {
        #expect(DockerPeer.resolve(pid: 0) == nil)
        #expect(DockerPeer.resolve(pid: -1) == nil)
        #expect(DockerPeer.resolve(pid: 4242) { _ in "docker" } == Self.docker)
        let own = try #require(DockerPeer.resolve(pid: getpid()))
        #expect(own.pid == getpid())
        #expect(own.name == GrantRequester.processName(of: getpid()))
        #expect(own.name?.isEmpty == false)
    }

    @Test("create, start and restart hand the engine the peer's requester, and nothing without a peer")
    func containerRoutes() async throws {
        let routes = ContainerRoutesTests()
        let body = #"{"Image":"alpine","Cmd":["sleep","60"]}"#
        #expect(try await routes.call(.POST, "/containers/create?name=web", body: body, peer: Self.docker).status == .created)
        let engineID = try #require(routes.engine.plans.first?.configuration.id)
        #expect(try await routes.call(.POST, "/containers/web/start", peer: Self.docker).status == .noContent)
        #expect(try await routes.call(.POST, "/containers/web/restart?t=1", peer: DockerPeer(pid: 5, name: "java")).status == .noContent)
        #expect(
            routes.engine.requesters == [
                "create docker (pid 4242)", "bootstrap \(engineID) docker (pid 4242)", "bootstrap \(engineID) java (pid 5)",
            ])

        // Control: a request with no peer names nobody, so the engine falls back to its own peer.
        let unnamed = ContainerRoutesTests()
        #expect(try await unnamed.call(.POST, "/containers/create?name=db", body: body).status == .created)
        let unnamedID = try #require(unnamed.engine.plans.first?.configuration.id)
        #expect(try await unnamed.call(.POST, "/containers/db/start").status == .noContent)
        #expect(unnamed.engine.requesters == ["create -", "bootstrap \(unnamedID) -"])
    }

    @Test("a network connect that remakes the container names the peer on the create")
    func networkConnect() async throws {
        let routes = NetworkRoutesTests()
        let created = try await routes.call(
            .POST, "/containers/create?name=m229-c", body: #"{"Image":"alpine","Cmd":["sleep","60"]}"#, on: routes.containerRouter)
        #expect(created.status == .created)
        let connected = try await routes.call(.POST, "/networks/m229-net/connect", body: #"{"Container":"m229-c"}"#, peer: Self.docker)
        #expect(connected.status == .ok)
        #expect(routes.engine.requesters == ["create -", "create docker (pid 4242)"])
    }

    @Test("archive PUT, GET and a HEAD that copies hand the engine the connection's own peer")
    func archiveOverTheSocket() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let own = try Self.ownRequester
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "tmp"), withIntermediateDirectories: true)
        var tar = TarBuilder()
        tar.file("greeting.txt", "hello\n")
        #expect(try await h.request("PUT", "/containers/box/archive?path=/tmp", body: tar.archive, contentType: "application/x-tar").status == 200)
        #expect(try await h.request("GET", "/containers/box/archive?path=/tmp/greeting.txt").status == 200)
        // Without `stat` in the image a HEAD copies the path out to look at it.
        h.tools.available.remove("stat")
        #expect(try await h.request("HEAD", "/containers/box/archive?path=/tmp/greeting.txt").status == 200)
        #expect(h.tools.copyRequesterCalls == ["in \(own)", "out \(own)", "out \(own)"])
    }

    @Test("the server reads the connecting process from the socket, with and without a user check")
    func serverReadsPeer() async throws {
        for allowedUID in [nil, getuid()] {
            let harness = try await DockerAPIServerTests.Harness.start(allowedUID: allowedUID) { router in
                router.add(.GET, "/peer") { request, _ in
                    .text(request.peer.map { "\($0.pid) \($0.requester)" } ?? "none")
                }
            }
            defer { Task { try? await harness.stop() } }
            try await harness.withClient { client in
                try await client.send("GET /v1.48/peer HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
                let answer = try await client.readToEnd()
                #expect(answer.hasPrefix("HTTP/1.1 200"))
                #expect(answer.hasSuffix("\r\n\r\n\(getpid()) \(try Self.ownRequester)"), "\(answer)")
            }
        }
    }
}
