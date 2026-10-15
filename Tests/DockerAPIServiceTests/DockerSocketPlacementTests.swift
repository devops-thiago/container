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

import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import DockerAPIService

struct DockerSocketPlacementTests {
    private func scratch() throws -> String {
        // Short, so a socket path inside fits in sun_path.
        let path = "/tmp/dsp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("a path the Docker CLI can dial is at most 103 bytes")
    func pathLimit() {
        #expect(DockerSocketPlacement.fits("/" + String(repeating: "a", count: 102)))
        #expect(!DockerSocketPlacement.fits("/" + String(repeating: "a", count: 103)))
        // Bytes, not characters.
        #expect(!DockerSocketPlacement.fits("/" + String(repeating: "é", count: 52)))
    }

    @Test("what is at the socket path decides whether to bind")
    func existing() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let empty = directory + "/none.sock"
        #expect(DockerSocketPlacement.inspect(empty) == .nothing)

        let file = directory + "/file.sock"
        FileManager.default.createFile(atPath: file, contents: Data("mine".utf8))
        #expect(DockerSocketPlacement.inspect(file) == .notASocket)

        // A socket file nobody listens on: bound once, then its descriptor closed.
        let stale = directory + "/stale.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(stale.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(DockerSocketPlacement.inspect(stale) == .staleSocket)

        let live = directory + "/live.sock"
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(unixDomainSocketPath: live).get()
        #expect(DockerSocketPlacement.inspect(live) == .liveSocket)
        try await server.close()
    }

    @Test("the status file round-trips and only this user can read it")
    func statusFile() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let url = URL(fileURLWithPath: directory).appending(path: DockerAPIStatus.fileName)
        let status = DockerAPIStatus(state: .pathTooLong, socketPath: "/a/long/path/docker.sock", pid: 42, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try status.write(to: url)
        #expect(try DockerAPIStatus.read(from: url) == status)
        #expect(status.pathBytes == 24 && status.maxPathBytes == 103)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("a closed gate answers instead of the route")
    func gate() async throws {
        var router = DockerRouter()
        router.add(.GET, "/_ping") { _, _ in .text("OK") }
        router.gate = { DockerAPIError(.serviceUnavailable, "SiliconShip is not running.") }
        let refused = await router.respond(to: try DockerRequest(method: .GET, uri: "/_ping", headers: [:], body: ByteBuffer()))
        guard case .data(let status, _, let body, _) = refused else {
            Issue.record("not data")
            return
        }
        #expect(status == .serviceUnavailable)
        #expect(String(buffer: body).contains("not running"))
        // Control: an open gate lets the route answer.
        router.gate = { nil }
        let served = await router.respond(to: try DockerRequest(method: .GET, uri: "/_ping", headers: [:], body: ByteBuffer()))
        guard case .data(.ok, _, _, _) = served else {
            Issue.record("expected 200")
            return
        }
    }
}
