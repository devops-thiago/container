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

@testable import ContainerAPIService

/// The broker's two routes, and the token that binds a label to whoever published it.
struct InstanceAttachHarnessTests {
    private let log = Logger(label: "attach-tests")

    /// An endpoint the way every real publisher makes one: from an anonymous listener that
    /// has a handler and is active. libxpc traps on an endpoint for a dormant connection.
    private func endpoint() -> xpc_endpoint_t {
        let listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { _ in }
        xpc_connection_activate(listener)
        return xpc_endpoint_create(listener)
    }

    /// The attach route's decision, as the route makes it once the envelope is parsed.
    private func attach(_ label: String, token: String?, endpoint: xpc_endpoint_t? = nil, pid: pid_t = getpid()) throws {
        try InstanceAttachHarness.record(
            label: label, endpoint: endpoint ?? self.endpoint(), token: token, pid: pid, log: log)
    }

    /// A pid that no longer exists: a child that has already exited and been reaped.
    private func deadPID() -> pid_t {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? child.run()
        child.waitUntilExit()
        return child.processIdentifier
    }

    /// The resolve route's decision.
    private func resolve(_ label: String, token: String?) throws -> xpc_endpoint_t? {
        try InstanceAttachHarness.lookup(label: label, token: token, log: log)
    }

    private func unique(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString)" }

    @Test("an attach without a token is refused")
    func attachRequiresToken() {
        let label = unique("helper")
        #expect(throws: ContainerizationError.self) {
            try attach(label, token: nil)
        }
        #expect(InstanceEndpoints.endpoint(label: label) == nil)
    }

    @Test("a label is owned by the token that first published it")
    func labelReplacementNeedsTheOwnersToken() throws {
        let label = unique("helper")
        let mine = endpoint()
        try attach(label, token: "owner-a", endpoint: mine)

        // Same user, different process: it cannot take the label over.
        #expect(throws: ContainerizationError.self) {
            try attach(label, token: "owner-b")
        }
        #expect(InstanceEndpoints.endpoint(label: label) === mine, "the original endpoint is still the one recorded")
        #expect(InstanceEndpoints.owner(label: label) == "owner-a")

        // The owner re-announcing (a new listener after a restart) goes through.
        let replacement = endpoint()
        try attach(label, token: "owner-a", endpoint: replacement)
        #expect(InstanceEndpoints.endpoint(label: label) === replacement)
    }

    @Test("resolve hands an endpoint only to its owner")
    func resolveRequiresTheOwnersToken() throws {
        let label = unique("network")
        let published = endpoint()
        try attach(label, token: "boot-secret", endpoint: published)

        #expect(throws: ContainerizationError.self, "no token") {
            _ = try resolve(label, token: nil)
        }
        #expect(throws: ContainerizationError.self, "another process's token") {
            _ = try resolve(label, token: "not-the-secret")
        }
        let served = try resolve(label, token: "boot-secret")
        #expect(served != nil, "a sibling helper holding the same token is served")
    }

    @Test("an embedder's grant listener cannot be resolved or replaced by a same-user process")
    func embedderLabelIsPrivateToItsPublisher() throws {
        // The embedder mints a token nobody else has and publishes its listener with it.
        let label = unique("grants")
        let embedderToken = UUID().uuidString
        try attach(label, token: embedderToken)

        // A harness that only shares the user's EUID: neither the apiserver's own boot token
        // nor a token of its choosing gets it the endpoint or the label.
        for token in ["apiserver-boot-token", "guess", ""] {
            #expect(throws: ContainerizationError.self) {
                _ = try resolve(label, token: token)
            }
            #expect(throws: ContainerizationError.self) {
                try attach(label, token: token)
            }
        }
        #expect(InstanceEndpoints.owner(label: label) == embedderToken)
    }

    @Test("a label whose publisher has exited can be taken by a successor's token")
    func deadPublisherLabelIsTakenOver() throws {
        let label = unique("grants")
        try attach(label, token: "old-app-token", pid: deadPID())
        // The relaunched app, with the token every new process mints, publishes again.
        let successor = endpoint()
        try attach(label, token: "new-app-token", endpoint: successor)
        #expect(InstanceEndpoints.endpoint(label: label) === successor)
        #expect(InstanceEndpoints.owner(label: label) == "new-app-token")
    }

    @Test("a label whose publisher is alive is not taken over by a different token")
    func livePublisherLabelIsKept() throws {
        let label = unique("grants")
        let mine = endpoint()
        try attach(label, token: "live-app-token", endpoint: mine, pid: getpid())
        #expect(throws: ContainerizationError.self) {
            try attach(label, token: "impostor", pid: getpid())
        }
        #expect(InstanceEndpoints.endpoint(label: label) === mine)
        #expect(InstanceEndpoints.owner(label: label) == "live-app-token")
    }

    @Test("a resolve for a label nobody published returns no endpoint rather than refusing")
    func unknownLabelResolvesToNothing() throws {
        let served = try resolve(unique("nobody"), token: "any")
        #expect(served == nil)
    }

    @Test("the process token is stable, private and unguessable in shape")
    func ownerTokenShape() {
        let token = InstanceAttach.ownerToken
        #expect(token == InstanceAttach.ownerToken, "one token per process")
        #expect(token.count == 64 || ProcessInfo.processInfo.environment[InstanceAttach.tokenEnvironmentName] != nil)
    }
}
