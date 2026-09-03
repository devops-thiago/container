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
import Testing

@testable import ContainerAPIClient
@testable import ContainerAPIService

struct HostDirectoryGrantCancellationTests {
    private final class SuspendedTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: CheckedContinuation<XPCMessage, any Error>?
        private var started = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var closeCalls = 0

        func send(_ message: XPCMessage, timeout: Duration) async throws -> XPCMessage {
            try await withCheckedThrowingContinuation { continuation in
                let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    reply = continuation
                    started = true
                    return startedWaiters
                }
                for waiter in waiters { waiter.resume() }
            }
        }

        func waitUntilStarted() async {
            if lock.withLock({ started }) { return }
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if started { return true }
                    startedWaiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func close() {
            let continuation = lock.withLock { () -> CheckedContinuation<XPCMessage, any Error>? in
                closeCalls += 1
                defer { reply = nil }
                return reply
            }
            continuation?.resume(throwing: CancellationError())
        }

        var closes: Int { lock.withLock { closeCalls } }
    }

    @Test("caller cancellation closes the one nested grant connection")
    func cancellationClosesNestedTransport() async {
        let probe = SuspendedTransport()
        let transport = HostDirectoryGrants.RequestTransport(
            send: { message, timeout in
                try await probe.send(message, timeout: timeout)
            },
            close: { probe.close() })
        let message = HostDirectoryGrants.requestMessage(
            path: "/private/unavailable",
            requestID: "request-a",
            patience: .seconds(300),
            ownerToken: "owner-token")

        let operation = Task {
            try await HostDirectoryGrants.send(
                message, timeout: .seconds(300), over: transport)
        }
        await probe.waitUntilStarted()
        operation.cancel()

        do {
            _ = try await operation.value
            Issue.record("a cancelled nested grant send unexpectedly returned")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(probe.closes >= 1)
    }

    @Test("local caller cancellation closes its dedicated outer API connection")
    func cancellationReachesAPIServerConnection() async {
        let probe = SuspendedTransport()
        let transport = ContainerClient.GrantAwareTransport(
            send: { message, timeout in
                try await probe.send(message, timeout: timeout)
            },
            close: { probe.close() })
        let message = XPCMessage(route: XPCRoute.containerCreate.rawValue)

        let operation = Task {
            try await ContainerClient.sendGrantAware(
                message, timeout: XPCClient.grantAwareResponseTimeout, over: transport)
        }
        await probe.waitUntilStarted()
        operation.cancel()

        do {
            _ = try await operation.value
            Issue.record("a cancelled grant-aware API send unexpectedly returned")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(probe.closes >= 1)
    }

    @Test("the engine carries one explicit identity and caller patience into the app request")
    func requestMessageCarriesIdentity() {
        let message = HostDirectoryGrants.requestMessage(
            path: "/Users/me/project",
            requestID: "request-137",
            patience: .seconds(42),
            ownerToken: "signed-owner")

        #expect(message.string(key: .hostDirectoryPath) == "/Users/me/project")
        #expect(message.string(key: .hostDirectoryRequestID) == "request-137")
        #expect(message.int64(key: .hostDirectoryDeadlineSeconds) == 42)
        #expect(message.string(key: InstanceAttach.tokenKey) == "signed-owner")
    }
}
