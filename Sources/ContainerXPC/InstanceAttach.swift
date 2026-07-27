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
    /// The apiserver route that hands one back out.
    public static let resolveRoute = "runtimeResolve"

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

    /// Resolve another instance's endpoint through the broker and seed it into
    /// this process's table, so the ordinary sync client lookup finds it.
    ///
    /// Brokered endpoints live in the apiserver's memory; a spawned helper that
    /// must dial a *different* instance (the runtime helper allocating an
    /// address from the network helper) has no other way to reach it, since the
    /// mach name it would otherwise dial belongs to no one.
    @discardableResult
    public static func resolve(identifier: String, log: Logger) async -> Bool {
        if InstanceEndpoints.endpoint(label: identifier) != nil { return true }
        guard let broker = brokerService else { return false }
        do {
            let client = XPCClient(service: broker)
            let message = XPCMessage(route: resolveRoute)
            message.set(key: "id", value: identifier)
            let reply = try await client.send(message, responseTimeout: .seconds(30))
            guard let endpoint = reply.endpoint(key: "endpoint") else {
                log.error("broker has no endpoint", metadata: ["id": "\(identifier)"])
                return false
            }
            InstanceEndpoints.attach(label: identifier, endpoint: endpoint)
            return true
        } catch {
            log.error(
                "failed to resolve instance endpoint",
                metadata: ["id": "\(identifier)", "error": "\(error)"])
            return false
        }
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
