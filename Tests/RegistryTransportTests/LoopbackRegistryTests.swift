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

import Testing

@testable import RegistryTransport

/// Docker's default insecure registries, `127.0.0.0/8` and `::1/128`, plus the name
/// `localhost`: the only registries a credential goes to over plain HTTP.
@Suite("Loopback registries")
struct LoopbackRegistryTests {
    @Test(
        "localhost, 127.0.0.0/8 and ::1 are loopback, with or without a port",
        arguments: [
            "localhost", "localhost:5000", "LOCALHOST:5000", "LocalHost",
            "127.0.0.1", "127.0.0.1:5000", "127.255.255.254", "127.1.2.3:443",
            "[::1]", "[::1]:5000", "[0:0:0:0:0:0:0:1]:5000",
            "[::ffff:127.0.0.1]:5000",
        ])
    func loopback(authority: String) {
        #expect(LoopbackRegistry.isLoopback(authority))
    }

    @Test(
        "every other host is not, a name that merely starts with localhost included",
        arguments: [
            "localhost.example.com", "localhost.example.com:5000", "localhost.", "localhostx:5000", "mylocalhost", "my.localhost",
            "128.0.0.1", "126.255.255.255:5000", "10.0.0.1:5000", "192.168.1.10", "172.16.0.1", "0.0.0.0", "169.254.0.1",
            "127.0.0", "127.000.000.001", "0x7f.0.0.1", "2130706433",
            "[::2]", "[::]:5000", "[fd00::1]:5000", "[fe80::1]", "[::1%lo0]:5000", "[::ffff:10.0.0.1]",
            "registry.example", "registry.example:5000", "ghcr.io", "docker.io", "", ":5000",
        ])
    func notLoopback(authority: String) {
        #expect(!LoopbackRegistry.isLoopback(authority))
    }

    @Test(
        "the host comes without its port or brackets",
        arguments: [
            ("localhost:5000", "localhost"), ("127.0.0.1", "127.0.0.1"), ("[::1]:5000", "::1"), ("[::1]", "::1"), ("::1", "::1"),
            ("registry.example:443", "registry.example"),
        ])
    func host(authority: String, host: String) {
        #expect(LoopbackRegistry.host(of: authority) == host)
    }
}
