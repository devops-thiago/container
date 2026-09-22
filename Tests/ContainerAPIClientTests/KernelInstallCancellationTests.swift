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
import Foundation
import Logging
import Synchronization
import Testing
import XPC

@testable import ContainerAPIClient

@Suite(.serialized)
struct KernelInstallCancellationTests {
    /// What the stand-in daemon's install route went through.
    private final class Route: Sendable {
        private struct State: Sendable {
            var started = false
            var cancelled = false
        }
        private let state = Mutex(State())

        var started: Bool { state.withLock { $0.started } }
        var cancelled: Bool { state.withLock { $0.cancelled } }
        func markStarted() { state.withLock { $0.started = true } }
        func markCancelled() { state.withLock { $0.cancelled = true } }

        func wait(for condition: @Sendable (Route) -> Bool, upTo limit: Duration = .seconds(5)) async throws -> Bool {
            let deadline = ContinuousClock.now + limit
            while !condition(self), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return condition(self)
        }
    }

    private func withDaemon<T: Sendable>(
        installing handler: @Sendable @escaping (XPCMessage) async throws -> XPCMessage,
        _ body: (XPCClient) async throws -> T
    ) async throws -> T {
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(
            connection: listener,
            routes: [
                XPCRoute.installKernel.rawValue: XPCServer.route(handler),
                "fixture-ready": XPCServer.route { $0.reply() },
            ],
            log: Logger(label: "kernel-install-test"))
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        // A connection of its own for the warm-up: the one under test has to be the install's
        // alone, because hanging it up is the thing being tested.
        let warmUp = XPCClient(endpoint: xpc_endpoint_create(listener), label: "kernel-install-test-ready")
        try await warmUp.send(XPCMessage(route: "fixture-ready"), responseTimeout: .seconds(10))
        warmUp.close()
        let transport = XPCClient(endpoint: xpc_endpoint_create(listener), label: "kernel-install-test")
        defer { transport.close() }
        return try await body(transport)
    }

    @Test("a cancelled install hangs up, which is the one thing that stops the daemon's download")
    func cancellationReachesTheDaemon() async throws {
        let route = Route()
        try await withDaemon(installing: { _ in
            route.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                route.markCancelled()
                throw error
            }
            throw CancellationError()
        }) { transport in
            let install = Task {
                try await ClientKernel.installKernelFromTar(
                    tarFile: "https://example.invalid/kernel.tar", kernelFilePath: "vmlinux", platform: .linuxArm,
                    expectedDigest: "sha256:\(String(repeating: "0", count: 64))", force: false, client: transport)
            }
            let started = try await route.wait(for: \.started)
            #expect(started)

            let cancelled = ContinuousClock.now
            install.cancel()
            let result = await install.result
            #expect(throws: CancellationError.self) { try result.get() }
            #expect(ContinuousClock.now - cancelled < .seconds(5), "the caller is released at once, not when the daemon replies")
            let reached = try await route.wait(for: \.cancelled)
            #expect(reached, "the daemon's work for the request was cancelled")
        }
    }

    @Test("an install that is left alone still returns what the daemon installed")
    func anUninterruptedInstallReturnsItsResult() async throws {
        let installation = KernelInstallation(name: "vmlinux-test", sha256: String(repeating: "a", count: 64))
        let returned = try await withDaemon(installing: { request in
            let reply = request.reply()
            reply.set(key: .kernelInstallation, value: try JSONEncoder().encode(installation))
            return reply
        }) { transport in
            try await ClientKernel.installKernelFromTar(
                tarFile: "https://example.invalid/kernel.tar", kernelFilePath: "vmlinux", platform: .linuxArm,
                expectedDigest: nil, force: false, client: transport)
        }
        #expect(returned == installation)
    }
}
