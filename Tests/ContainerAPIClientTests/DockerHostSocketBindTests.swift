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
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

/// A unix socket in a folder of its own: listening, or left behind by a server that stopped.
final class TestSocket {
    let directory: URL
    let path: String
    private var descriptor: Int32

    init(listening: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "dhs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "d.sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        if listening {
            guard listen(descriptor, 1) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        } else {
            // The file stays; nothing answers on it.
            close(descriptor)
            descriptor = -1
        }
    }

    /// A symbolic link to this socket, beside it.
    func link(named name: String) throws -> String {
        let link = directory.appending(path: name).path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        return link
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A bind of the host's Docker socket, as `container run -v` and `--mount`, and Compose through
/// them, give it, in any spelling or through any link: it mounts the engine's own socket, never
/// the host's (Docker Desktop's on a Mac that has it). The host's sockets here are test sockets;
/// nothing touches the real /var/run/docker.sock.
struct DockerHostSocketBindTests {
    /// The engine's socket, answering or not, and a stand-in for the host's Docker socket.
    private static func binding(engine: TestSocket, host: TestSocket, answering: Bool = true) -> DockerSocketBinding {
        let path = engine.path
        return DockerSocketBinding(enginePath: { path }, home: "/Users/me", hostSockets: [host.path], answers: { _ in answering })
    }

    @Test(
        "every spelling of the host's Docker socket binds the engine's",
        arguments: [
            "/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock", "/VAR/run/docker.sock", "/var/run/Docker.sock",
            "/Private/Var/Run/Docker.Sock", "/var/run/../run/docker.sock", "/Users/me/.docker/run/docker.sock", "/users/ME/.Docker/run/docker.sock",
        ])
    func spellings(path: String) throws {
        let engine = try TestSocket()
        let host = try TestSocket()
        #expect(try Self.binding(engine: engine, host: host).bindSource(path) == engine.path)
    }

    @Test("the host's socket by another path, or through a link to it, binds the engine's")
    func sameFile() throws {
        let engine = try TestSocket()
        let host = try TestSocket()
        let binding = Self.binding(engine: engine, host: host)
        #expect(try binding.bindSource(host.path) == engine.path)
        #expect(try binding.bindSource(try host.link(named: "my-docker.sock")) == engine.path)
    }

    @Test("other sockets and paths bind as they are")
    func others() throws {
        let engine = try TestSocket()
        let host = try TestSocket()
        let other = try TestSocket()
        let binding = Self.binding(engine: engine, host: host)
        for path in [other.path, try other.link(named: "other.sock"), "/var/run", "/var/run/docker.sock.d", "/tmp/docker.sock", "/Users/someone/.docker/run/docker.sock"] {
            #expect(try binding.bindSource(path) == path)
        }
    }

    @Test("with nothing answering on the engine's socket, the bind is refused, never made of the host's")
    func refusesWhenNotServed() throws {
        let engine = try TestSocket()
        let host = try TestSocket()
        #expect {
            _ = try Self.binding(engine: engine, host: host, answering: false).bindSource("/var/run/docker.sock")
        } throws: { error in
            (error as? ContainerizationError)?.message == DockerHostSocket.notServedMessage
        }
    }

    @Test("-v and --mount bind the engine's socket for the host's, and refuse when it does not answer")
    func parsers() throws {
        let engine = try TestSocket()
        let host = try TestSocket()
        let served = Self.binding(engine: engine, host: host)
        let forms: [(DockerSocketBinding) throws -> VolumeOrFilesystem] = [
            { try Parser.volume("/var/run/docker.sock:/var/run/docker.sock", dockerSocket: $0) },
            { try Parser.volume("/VAR/run/docker.sock:/var/run/docker-host.sock:ro", dockerSocket: $0) },
            { try Parser.mount("type=bind,source=/Users/me/.docker/run/docker.sock,target=/var/run/docker.sock", dockerSocket: $0) },
            { try Parser.volume("\(host.path):/var/run/docker.sock", dockerSocket: $0) },
        ]
        for form in forms {
            guard case .filesystem(let filesystem) = try form(served) else {
                Issue.record("a bind became a volume")
                continue
            }
            #expect(filesystem.source == engine.path)
            #expect(throws: ContainerizationError.self) { _ = try form(Self.binding(engine: engine, host: host, answering: false)) }
        }
    }
}
