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

import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

/// A bind of the host's Docker socket, as `container run -v` and `--mount`, and Compose through
/// them, give it. Docker Desktop mounts its engine's socket for it; this engine mounts its own,
/// and never what the host has at that path, which on a Mac with Docker Desktop is Docker
/// Desktop's.
struct DockerHostSocketBindTests {
    /// A unix socket something listens on, in a folder of its own.
    private final class ServedSocket {
        let directory: URL
        let path: String
        private let descriptor: Int32

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "dhs-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appending(path: "docker.sock").path
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(descriptor, 1) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        }

        deinit {
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("the host's Docker socket binds the engine's", arguments: ["/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock"])
    func mapsTheHostSocket(path: String) throws {
        let served = try ServedSocket()
        #expect(try Parser.bindSource(path, enginePath: served.path) == served.path)
    }

    @Test("with nothing serving the engine's socket, the bind is refused, never made of the host's")
    func refusesWhenNotServed() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "dhs-none-\(UUID().uuidString.prefix(8))/docker.sock").path
        #expect {
            _ = try Parser.bindSource("/var/run/docker.sock", enginePath: missing)
        } throws: { error in
            (error as? ContainerizationError)?.message == DockerHostSocket.notServedMessage
        }
        // A plain file where the socket would be is not a socket being served either.
        let served = try ServedSocket()
        let file = served.directory.appending(path: "plain").path
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(throws: ContainerizationError.self) { _ = try Parser.bindSource("/var/run/docker.sock", enginePath: file) }
    }

    @Test("every other path binds as it is")
    func leavesOtherPaths() throws {
        for path in ["/Users/me/.docker/run/docker.sock", "/var/run", "/var/run/docker.sock.d", "/tmp/docker.sock"] {
            #expect(try Parser.bindSource(path, enginePath: "/nowhere/docker.sock") == path)
        }
    }

    /// The parsers as `run` calls them, with the engine's real socket path: they mount that, or
    /// refuse, whatever the host has at /var/run/docker.sock.
    @Test("-v and --mount of the host's Docker socket never mount the host's")
    func parsersNeverMountTheHostSocket() throws {
        let engine = PathUtils.dockerSocketPath()
        let forms: [() throws -> VolumeOrFilesystem] = [
            { try Parser.volume("/var/run/docker.sock:/var/run/docker.sock") },
            { try Parser.volume("/var/run/docker.sock:/var/run/docker-host.sock:ro") },
            { try Parser.mount("type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock") },
        ]
        for form in forms {
            do {
                guard case .filesystem(let filesystem) = try form() else {
                    Issue.record("a bind became a volume")
                    continue
                }
                #expect(filesystem.source == engine)
            } catch let error as ContainerizationError {
                #expect(error.message == DockerHostSocket.notServedMessage)
            }
        }
    }
}
