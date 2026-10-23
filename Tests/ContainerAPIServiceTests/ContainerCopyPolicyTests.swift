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

import ContainerXPC
import Foundation
import Logging
import Testing
import XPC

@testable import ContainerAPIClient
@testable import ContainerAPIService

struct ContainerCopyPolicyTests {
    @Test("running copies keep their policy through client, API server, and runtime XPC", arguments: [false, true], [false, true])
    func runningCopyPolicy(strict: Bool, archive: Bool) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let source = f.root.appendingPathComponent("source")
        try Data("payload".utf8).write(to: source)
        let log = Logger(label: "ContainerCopyPolicyTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(
            connection: listener,
            routes: [
                XPCRoute.containerCopyIn.rawValue: XPCServer.route { message in
                    try await harness.copyIn(message, peerPID: 0)
                }
            ], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "copy-policy-test")
        defer { xpc.close() }
        try await ContainerClient(xpcClient: xpc).copyIn(
            id: configuration.id, source: source.path, destination: "/tmp", noOverwriteDirNonDir: strict, copyAsArchive: archive)
        #expect(f.lastRuntime?.noOverwritePolicies == [strict])
        #expect(f.lastRuntime?.archiveCopies == [archive])
    }
}
