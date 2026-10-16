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
import ContainerizationError
import Foundation
import Logging
import Testing
import XPC

/// A server asked for a route it does not have answers at once that it does not have it,
/// rather than leaving the client to wait out its timeout.
struct XPCUnknownRouteTests {
    @Test("an unknown route is answered with unsupported; a known one still answers")
    func unknownRouteAnswers() async throws {
        let log = Logger(label: "XPCUnknownRouteTests")
        let listener = xpc_connection_create(nil, nil)
        let routes: [String: XPCServer.RouteHandler] = [
            "known": XPCServer.route { message in message.reply() }
        ]
        let server = XPCServer(connection: listener, routes: routes, log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let client = XPCClient(endpoint: xpc_endpoint_create(listener), label: "unknown-route-test")
        defer { client.close() }

        let clock = ContinuousClock()
        let began = clock.now
        do {
            _ = try await client.send(XPCMessage(route: "not-a-route"), responseTimeout: .seconds(20))
            Issue.record("an unknown route was answered without an error")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.unsupported))
            #expect(error.message.contains("not-a-route"))
        }
        // Answered, not timed out.
        #expect(clock.now - began < .seconds(10))

        // The control: a route the server has is answered normally.
        _ = try await client.send(XPCMessage(route: "known"), responseTimeout: .seconds(5))
    }
}
