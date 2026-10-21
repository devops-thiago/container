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

    /// A unix socket bound at `path` and not listening, its descriptor still open.
    private func boundSocket(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return fd
    }

    private func inode(_ path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_ino : nil
    }

    /// What an agent does once it holds the claim: bind, note the socket, write the status.
    private func serve(_ claim: DockerSocketClaim, status: URL, backlog: Int32 = 64) async throws -> any Channel {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: backlog)
            .bind(unixDomainSocketPath: claim.socketPath).get()
        try claim.bound()
        try claim.publish(DockerAPIStatus(state: .listening, socketPath: claim.socketPath), to: status)
        return server
    }

    @Test("a second agent on the same path stops with a clear message, and the first keeps serving it")
    func secondAgent() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + DockerSocketPlacement.socketName
        let status = URL(fileURLWithPath: directory).appending(path: DockerAPIStatus.fileName)

        let first = try DockerSocketClaim.claim(path)
        let server = try await serve(first, status: status)
        let served = inode(path)
        let published = try DockerAPIStatus.read(from: status)

        #expect(throws: DockerSocketRefusal.served(path: path)) { try DockerSocketClaim.claim(path) }
        #expect(DockerSocketRefusal.served(path: path).description == "\(path) is already being served")
        #expect(DockerSocketPlacement.inspect(path) == .liveSocket)
        #expect(inode(path) == served)
        #expect(try DockerAPIStatus.read(from: status) == published)

        // The first agent stopping leaves nothing, and frees the path for the next one.
        try await server.close()
        first.release()
        #expect(DockerSocketPlacement.inspect(path) == .nothing)
        #expect(!FileManager.default.fileExists(atPath: status.path))
        let next = try DockerSocketClaim.claim(path)
        next.release()
    }

    @Test("a socket whose backlog is full looks stale to a connect on macOS, and the lock keeps a second agent off it")
    func fullBacklog() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + DockerSocketPlacement.socketName
        let status = URL(fileURLWithPath: directory).appending(path: DockerAPIStatus.fileName)
        let first = try DockerSocketClaim.claim(path)
        defer { first.release() }
        // Nothing accepts, so the connects pile up in the backlog until it is full.
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(listen(listener, 1) == 0)
        try first.bound()
        try first.publish(DockerAPIStatus(state: .listening, socketPath: path), to: status)
        var pending: [Int32] = []
        defer { pending.forEach { close($0) } }
        while DockerSocketPlacement.dial(path) == 0, pending.count < 64 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            pending.append(fd)
        }
        let served = inode(path)
        #expect(DockerSocketPlacement.inspect(path) == .staleSocket)
        #expect(throws: DockerSocketRefusal.served(path: path)) { try DockerSocketClaim.claim(path) }
        #expect(inode(path) == served)
        #expect(FileManager.default.fileExists(atPath: status.path))
    }

    @Test("an agent removes only the socket and status file it made")
    func releaseOnlyOwn() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/" + DockerSocketPlacement.socketName
        let status = URL(fileURLWithPath: directory).appending(path: DockerAPIStatus.fileName)

        // A bind that failed made nothing: what another agent bound at the path stays.
        let loser = try DockerSocketClaim.claim(path)
        let other = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(unixDomainSocketPath: path).get()
        let otherStatus = DockerAPIStatus(state: .listening, socketPath: path, pid: 1, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try otherStatus.write(to: status)
        await #expect(throws: (any Error).self) {
            try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(unixDomainSocketPath: path).get()
        }
        loser.release()
        #expect(DockerSocketPlacement.inspect(path) == .liveSocket)
        #expect(try DockerAPIStatus.read(from: status) == otherStatus)
        try await other.close()
        unlink(path)

        // Replaced after it bound: the agent's exit leaves the new socket and status alone.
        let first = try DockerSocketClaim.claim(path)
        let server = try await serve(first, status: status)
        try await server.close()
        unlink(path)
        let replacement = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(unixDomainSocketPath: path).get()
        try otherStatus.write(to: status)
        first.release()
        #expect(DockerSocketPlacement.inspect(path) == .liveSocket)
        #expect(try DockerAPIStatus.read(from: status) == otherStatus)
        try await replacement.close()
    }

    @Test("only a refused connect makes a socket stale: one that cannot be reached for another reason is left alone")
    func unreachable() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // Bound and not listening: refused, as after an agent that died.
        let refused = directory + "/refused.sock"
        let fd = boundSocket(refused)
        defer { close(fd) }
        #expect(DockerSocketPlacement.inspect(refused) == .staleSocket)

        // Without write permission a connect fails with EACCES: it may well be served.
        let closed = directory + "/closed.sock"
        let other = boundSocket(closed)
        defer { close(other) }
        #expect(listen(other, 4) == 0)
        #expect(chmod(closed, 0) == 0)
        #expect(DockerSocketPlacement.inspect(closed) == .unreachableSocket(errno: EACCES))
        #expect(throws: DockerSocketRefusal.unreachable(path: closed, errno: EACCES)) { try DockerSocketClaim.claim(closed) }
        #expect(FileManager.default.fileExists(atPath: closed))
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
