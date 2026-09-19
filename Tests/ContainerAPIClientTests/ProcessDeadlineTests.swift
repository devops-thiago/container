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
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import Synchronization
import Testing
import XPC

@testable import ContainerAPIClient

@Suite(.serialized)
struct ProcessDeadlineTests {
    private func pipeline(stall: String?, delayEveryReply: Bool = false, expired: Bool = false) async throws -> (Duration, [String], (any Error)?) {
        let seen = Mutex<[String]>([])
        let routes = [XPCRoute.containerCreateProcess.rawValue, XPCRoute.containerStartProcess.rawValue, XPCRoute.containerWait.rawValue]
        var handlers = Dictionary(
            uniqueKeysWithValues: routes.map { route in
                (
                    route,
                    XPCServer.route { request in
                        seen.withLock { $0.append(route) }
                        if route == stall { try await Task.sleep(for: .seconds(5)) }
                        if delayEveryReply { try await Task.sleep(for: .milliseconds(400)) }
                        let reply = request.reply()
                        reply.set(key: XPCKeys.exitCode.rawValue, value: Int64(0))
                        return reply
                    }
                )
            })
        handlers["fixture-ready"] = XPCServer.route { $0.reply() }
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: handlers, log: Logger(label: "process-deadline-test"))
        let listening = Task { try await server.listen() }
        let transport = XPCClient(endpoint: xpc_endpoint_create(listener), label: "process-deadline-test")
        defer {
            transport.close()
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        // Establish the listener before measuring a request budget: cold XPC activation
        // competes with the full suite's initial scheduling burst.
        try await transport.send(XPCMessage(route: "fixture-ready"), responseTimeout: .seconds(10))
        let client = ContainerClient(xpcClient: transport)
        let start = ContinuousClock.now
        var failure: (any Error)?
        do {
            let process = try await client.createProcess(
                containerId: "fixture", processId: UUID().uuidString,
                configuration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [], terminal: false),
                stdio: [], deadline: start.advanced(by: .milliseconds(expired ? -1 : (delayEveryReply || stall != nil ? 1000 : 3000))))
            try await process.start()
            _ = try await process.wait()
        } catch { failure = error }
        return (start.duration(to: .now), seen.withLock { $0 }, failure)
    }

    @Test(
        "a nonreplying create, start or wait is bounded by the actual XPC timer",
        arguments: [XPCRoute.containerCreateProcess.rawValue, XPCRoute.containerStartProcess.rawValue, XPCRoute.containerWait.rawValue])
    func stalledReply(route: String) async throws {
        let (elapsed, seen, error) = try await pipeline(stall: route)
        #expect(seen.contains(route), "the intended transport stage must actually execute")
        #expect(error != nil)
        #expect(elapsed < .seconds(3), "must not wait for the five-second stalled server reply")
    }

    @Test("create/start/wait share a deadline rather than receiving fresh budgets")
    func cumulativeBudget() async throws {
        let (elapsed, seen, error) = try await pipeline(stall: nil, delayEveryReply: true)
        #expect(seen.first == XPCRoute.containerCreateProcess.rawValue)
        #expect(error != nil, "three 400ms stages cannot complete in a one-second budget")
        #expect(elapsed < .seconds(3))
    }

    @Test("an expired deadline refuses the request before sending it")
    func expiredDeadline() async throws {
        let (_, seen, error) = try await pipeline(stall: nil, expired: true)
        #expect(seen.isEmpty)
        #expect(error != nil)
    }

    @Test("cancelling an in-flight probe releases its wait and preserves the shared connection")
    func cancelledReply() async throws {
        let entered = Mutex(false)
        let listener = xpc_connection_create(nil, nil)
        let route = XPCRoute.containerCreateProcess.rawValue
        let server = XPCServer(
            connection: listener,
            routes: [
                route: XPCServer.route { request in
                    let first = entered.withLock { value in
                        let first = !value
                        value = true
                        return first
                    }
                    if first { try await Task.sleep(for: .seconds(5)) }
                    return request.reply()
                }
            ], log: Logger(label: "process-cancellation-test"))
        let listening = Task { try await server.listen() }
        let transport = XPCClient(endpoint: xpc_endpoint_create(listener), label: "process-cancellation-test")
        defer {
            transport.close()
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let client = ContainerClient(xpcClient: transport)
        let pending = Task {
            try await client.createProcess(
                containerId: "fixture", processId: "cancelled",
                configuration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [], terminal: false),
                stdio: [], deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered.withLock({ $0 }) && ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 })
        let cancelledAt = ContinuousClock.now
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("a cancelled process request returned success")
        } catch {
            var cause: any Error = error
            while let wrapped = cause as? ContainerizationError, let next = wrapped.cause { cause = next }
            #expect(cause is CancellationError)
        }
        #expect(cancelledAt.duration(to: .now) < .seconds(3), "cancellation must release the await before the delayed reply")
        _ = try await client.createProcess(
            containerId: "fixture", processId: "after-cancellation",
            configuration: ProcessConfiguration(executable: "/bin/true", arguments: [], environment: [], terminal: false),
            stdio: [], deadline: ContinuousClock.now.advanced(by: .seconds(3)))
    }

    @Test("on-time create/start/wait still succeeds")
    func successfulReply() async throws {
        let (_, seen, error) = try await pipeline(stall: nil)
        #expect(error == nil)
        #expect(seen.count == 3)
    }
}
