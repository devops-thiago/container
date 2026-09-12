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

import ContainerAPIClient
import ContainerXPC
import Foundation
import Logging
import Testing
import XPC

@testable import container_apiserver

/// Exercise the production startup route wiring, not just a separately built health harness.
@Suite(.serialized)
@MainActor
struct APIServerHealthIdentityTests {
    @Test("health identifies an SMAppService process without a legacy generation", arguments: [false, true])
    func processIdentity(includeLegacyGeneration: Bool) async throws {
        let nonce = UUID().uuidString
        let generation = UUID().uuidString
        var start = APIServer.Start()
        start.lifecycleGenerationOption = includeLegacyGeneration ? generation : nil
        let log = Logger(label: "health-wiring-test")
        var routes: [XPCRoute: XPCServer.RouteHandler] = [:]
        start.initializeHealthCheckService(processNonce: nonce, log: log, routes: &routes)

        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) }), log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let client = XPCClient(endpoint: xpc_endpoint_create(listener), label: "health-wiring-test")
        defer { client.close() }
        for _ in 0..<2 {
            let reply = try await client.send(XPCMessage(route: XPCRoute.ping.rawValue), responseTimeout: .seconds(5))
            #expect(reply.string(key: XPCKeys.processNonce.rawValue) == nonce)
            #expect(reply.string(key: XPCKeys.lifecycleGeneration.rawValue) == (includeLegacyGeneration ? generation : nil))
            #expect(reply.uint64IfPresent(key: XPCKeys.lifecycleProtocolVersion.rawValue) == (includeLegacyGeneration ? SystemHealth.currentLifecycleProtocolVersion : nil))
        }
    }
}
