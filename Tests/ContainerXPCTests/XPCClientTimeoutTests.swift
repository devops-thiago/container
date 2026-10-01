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

import ContainerizationError
import Foundation
import Synchronization
import Testing
import XPC

@testable import ContainerXPC

struct XPCClientTimeoutTests {
    private static let delayKey = "test.reply.delay.ms"
    private static let answerKey = "test.answer"

    /// An XPC peer on an anonymous listener. A request carrying `delayKey` is answered after that
    /// many milliseconds. A request without it is held and never answered, like a peer that is
    /// alive but stuck: releasing it unanswered would make libxpc fail the sender's reply handler.
    private final class Peer: @unchecked Sendable {
        let listener: xpc_connection_t
        let client: XPCClient
        private let unanswered: HeldRequests

        init() {
            let unanswered = HeldRequests()
            let listener = xpc_connection_create(nil, nil)
            xpc_connection_set_event_handler(listener) { peer in
                guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
                    return
                }
                xpc_connection_set_event_handler(peer) { request in
                    guard xpc_get_type(request) == XPC_TYPE_DICTIONARY else {
                        return
                    }
                    guard xpc_dictionary_get_value(request, XPCClientTimeoutTests.delayKey) != nil else {
                        unanswered.hold(request)
                        return
                    }
                    let delay = xpc_dictionary_get_int64(request, XPCClientTimeoutTests.delayKey)
                    let reply = xpc_dictionary_create_reply(request)!
                    xpc_dictionary_set_string(reply, XPCClientTimeoutTests.answerKey, "pong")
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delay))) {
                        xpc_connection_send_message(peer, reply)
                    }
                }
                xpc_connection_activate(peer)
            }
            xpc_connection_activate(listener)
            self.unanswered = unanswered
            self.listener = listener
            let connection = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
            self.client = XPCClient(connection: connection, label: "com.apple.container.test.peer")
        }
    }

    private final class HeldRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [xpc_object_t] = []

        func hold(_ request: xpc_object_t) {
            lock.withLock { requests.append(request) }
        }
    }

    private static func request(replyingAfter delay: Int64? = nil) -> XPCMessage {
        let message = XPCMessage(route: "ping")
        if let delay {
            xpc_dictionary_set_int64(message.underlying, delayKey, delay)
        }
        return message
    }

    @Test
    func sendFailsWithATimeoutWhenThePeerNeverReplies() async throws {
        let peer = Peer()
        let outcome = Mutex<Result<XPCMessage, any Error>?>(nil)

        Task {
            do {
                let reply = try await peer.client.send(Self.request(), responseTimeout: .milliseconds(200))
                outcome.withLock { $0 = .success(reply) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        for _ in 0..<30 where outcome.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let result = outcome.withLock({ $0 }) else {
            Issue.record("send was still waiting on a silent peer 3 seconds after its 200ms timeout")
            return
        }
        guard case .failure(let error) = result else {
            Issue.record("send returned a reply from a peer that never replied")
            return
        }
        #expect(
            (error as? ContainerizationError)?.message.contains("XPC timeout") == true,
            "unexpected error: \(error)")
    }

    @Test
    func sendReturnsTheReplyThatArrivesBeforeTheTimeout() async throws {
        let peer = Peer()
        let reply = try await peer.client.send(Self.request(replyingAfter: 0), responseTimeout: .seconds(5))
        #expect(reply.string(key: Self.answerKey) == "pong")
    }

    @Test
    func sendWithoutATimeoutWaitsForTheReply() async throws {
        let peer = Peer()
        let reply = try await peer.client.send(Self.request(replyingAfter: 300))
        #expect(reply.string(key: Self.answerKey) == "pong")
    }

    @Test
    func aReplyThatArrivesAfterTheTimeoutIsIgnored() async throws {
        let peer = Peer()

        await #expect {
            try await peer.client.send(Self.request(replyingAfter: 600), responseTimeout: .milliseconds(100))
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("XPC timeout") == true
        }
        try await Task.sleep(for: .seconds(1))

        let reply = try await peer.client.send(Self.request(replyingAfter: 0), responseTimeout: .seconds(5))
        #expect(reply.string(key: Self.answerKey) == "pong")
    }
}
