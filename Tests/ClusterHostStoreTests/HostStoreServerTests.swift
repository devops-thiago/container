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
import ContainerizationError
import Foundation
import Logging
import NIOHTTP1
import Testing

@testable import ClusterHostStoreService

struct LookupStatusTests {
    @Test func notFoundIs404() {
        #expect(HostStoreServer.status(for: ContainerizationError(.notFound, message: "missing")) == .notFound)
    }

    @Test func invalidArgumentIs400() {
        #expect(HostStoreServer.status(for: ContainerizationError(.invalidArgument, message: "bad digest")) == .badRequest)
    }

    @Test func otherErrorIs500() {
        #expect(HostStoreServer.status(for: CancellationError()) == .internalServerError)
    }
}

struct ConnectionLimitTests {
    @Test func acquireFailsPastMax() {
        let limit = ConnectionLimit(max: 2)
        #expect(limit.acquire())
        #expect(limit.acquire())
        #expect(!limit.acquire())
    }

    @Test func releaseFreesASlot() {
        let limit = ConnectionLimit(max: 1)
        #expect(limit.acquire())
        limit.release()
        #expect(limit.acquire())
    }
}

/// A client that connects and hangs up before the server accepts is the host store's
/// problem, not a reason to stop serving every node.
struct HostStoreServerAcceptTests {
    private static func connect(_ path: String, reset: Bool) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        if reset {
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            close(fd)
            return 0
        }
        return fd
    }

    @Test func clientsThatHangUpAtOnceDoNotStopTheServer() async throws {
        let directory = "/tmp/hs-accept-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/hs.sock"
        let server = HostStoreServer(containerSystemConfig: ContainerSystemConfig(), log: Logger(label: "host-store-accept-tests"))
        let running = Task { try await server.run(socketPath: path) }
        defer { running.cancel() }

        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<50 {
            let plain = Self.connect(path, reset: false)
            if plain >= 0 { close(plain) }
            _ = Self.connect(path, reset: true)
        }
        try await Task.sleep(for: .milliseconds(200))

        // Still serving: a request for nothing gets an answer.
        let fd = Self.connect(path, reset: false)
        #expect(fd >= 0)
        defer { close(fd) }
        let request = Array("GET /nothing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8)
        #expect(write(fd, request, request.count) == request.count)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        #expect(count > 0)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
    }
}
