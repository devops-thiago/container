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
import Testing

@testable import ContainerResource

struct DockerHostSocketTests {
    private static func socketPath() -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dhst-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "s.sock").path)
    }

    private static func bound(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return fd
    }

    @Test("served means something answers: a socket file nobody listens on is not served")
    func answers() throws {
        let (directory, path) = Self.socketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!DockerHostSocket.answers(at: path))
        let fd = Self.bound(path)
        #expect(listen(fd, 1) == 0)
        #expect(DockerHostSocket.answers(at: path))
        close(fd)
        // The file is still there; a stopped server left it.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!DockerHostSocket.answers(at: path))
    }

    @Test("the host's socket is matched by spelling without case, or by file, never by a name alone")
    func names() throws {
        let (directory, host) = Self.socketPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = Self.bound(host)
        defer { close(fd) }
        let link = directory.appending(path: "link.sock").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: host)
        let plain = directory.appending(path: "docker.sock").path
        FileManager.default.createFile(atPath: plain, contents: Data())
        #expect(DockerHostSocket.names("/VAR/RUN/DOCKER.SOCK", home: "/Users/me", hostSockets: [host]))
        #expect(DockerHostSocket.names("/Users/me/.docker/run/docker.sock", home: "/Users/me", hostSockets: [host]))
        #expect(DockerHostSocket.names(link, home: "/Users/me", hostSockets: [host]))
        #expect(!DockerHostSocket.names(plain, home: "/Users/me", hostSockets: [host]))
        #expect(!DockerHostSocket.names("/Users/other/.docker/run/docker.sock", home: "/Users/me", hostSockets: [host]))
        #expect(DockerHostSocket.bindSource(for: link, enginePath: "/engine.sock", home: "/Users/me", hostSockets: [host]) == "/engine.sock")
        #expect(DockerHostSocket.bindSource(for: plain, enginePath: "/engine.sock", home: "/Users/me", hostSockets: [host]) == plain)
    }
}
