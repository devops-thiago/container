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
import Logging
import XPC

/// How a spawned plugin instance publishes itself under sandboxed embedding.
///
/// A posix_spawned helper cannot own a launchd mach service name, so instead of
/// listening on one it creates an anonymous listener and hands that endpoint to
/// the apiserver, which brokers it to clients. The apiserver's service name
/// arrives in `CONTAINER_ATTACH_SERVICE`; when it is unset the helper is running
/// the ordinary unsandboxed launchd path and keeps its mach service.
public enum InstanceAttach {
    public static let environmentName = "CONTAINER_ATTACH_SERVICE"
    /// The apiserver route that records an instance endpoint.
    public static let route = "runtimeAttach"

    public static var brokerService: String? {
        guard let value = ProcessInfo.processInfo.environment[environmentName], !value.isEmpty
        else { return nil }
        return value
    }

    /// Publish `connection`'s endpoint to the broker under the mach service name
    /// this instance would own unsandboxed. That name doubles as the broker key,
    /// so clients look up exactly what they would otherwise dial.
    ///
    /// No-op when the broker is unset (ordinary unsandboxed launchd path).
    public static func announce(
        identifier: String,
        connection: xpc_connection_t,
        log: Logger
    ) async throws {
        guard let broker = brokerService else { return }
        log.info(
            "announcing instance endpoint",
            metadata: ["broker": "\(broker)", "identifier": "\(identifier)"])
        let client = XPCClient(service: broker)
        let message = XPCMessage(route: route)
        message.set(key: "id", value: identifier)
        message.set(key: "endpoint", value: xpc_endpoint_create(connection))
        message.set(key: "pid", value: Int64(getpid()))
        _ = try await client.send(message, responseTimeout: .seconds(30))
    }

    /// Serve `routes` the way this deployment requires: over an anonymous
    /// connection announced to the broker, or on `identifier` as a mach service.
    public static func serve(
        identifier: String,
        routes: [String: XPCServer.RouteHandler],
        log: Logger
    ) async throws {
        guard brokerService != nil else {
            try await XPCServer(identifier: identifier, routes: routes, log: log).listen()
            return
        }
        nonisolated(unsafe) let connection = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: connection, routes: routes, log: log)
        try await announce(identifier: identifier, connection: connection, log: log)
        try await server.listen()
    }
}
