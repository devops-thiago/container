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
import ContainerizationError
import Foundation
import Logging
import Testing
import XPC

@testable import ContainerAPIService

/// The broker's routes, the authenticated fixed grant label, and helper-token compatibility.
@Suite(.serialized)
struct InstanceAttachHarnessTests {
    private let log = Logger(label: "attach-tests")

    private func endpoint() -> xpc_endpoint_t {
        let listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { _ in }
        xpc_connection_activate(listener)
        return xpc_endpoint_create(listener)
    }

    private func attach(
        _ label: String,
        token: String?,
        endpoint: xpc_endpoint_t? = nil,
        peerPID: pid_t = getpid(),
        authorizedPublisher: Bool = true
    ) throws {
        try InstanceAttachHarness.record(
            label: label,
            endpoint: endpoint ?? self.endpoint(),
            token: token,
            peerPID: peerPID,
            authorizedPublisher: authorizedPublisher,
            log: log)
    }

    private func attachMessage(
        _ label: String,
        token: String,
        payloadPID: pid_t,
        endpoint: xpc_endpoint_t? = nil
    ) -> XPCMessage {
        let message = XPCMessage(route: InstanceAttach.route)
        message.set(key: "id", value: label)
        message.set(key: "endpoint", value: endpoint ?? self.endpoint())
        message.set(key: "pid", value: Int64(payloadPID))
        message.set(key: InstanceAttach.tokenKey, value: token)
        return message
    }

    private func deadPID() -> pid_t {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? child.run()
        child.waitUntilExit()
        return child.processIdentifier
    }

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

    @Test("spawned helper labels retain inherited-token publication and reject same-user squatters")
    func helperTokenFlowRemainsAvailable() throws {
        let label = unique("runtime")
        #expect(
            InstanceAttachHarness.publisherAuthorized(
                label: label,
                token: "spawn-token",
                hostAppVerified: false,
                helperOwnerToken: "spawn-token"))
        #expect(
            !InstanceAttachHarness.publisherAuthorized(
                label: label,
                token: "attacker-token",
                hostAppVerified: false,
                helperOwnerToken: "spawn-token"))

        let first = endpoint()
        try attach(label, token: "spawn-token", endpoint: first)
        #expect(try resolve(label, token: "spawn-token") != nil)

        let replacement = endpoint()
        try attach(label, token: "spawn-token", endpoint: replacement)
        #expect(InstanceEndpoints.endpoint(label: label) === replacement)
    }

    @Test("a label is owned by the token that first published it")
    func labelReplacementNeedsTheOwnersToken() throws {
        let label = unique("helper")
        let mine = endpoint()
        try attach(label, token: "owner-a", endpoint: mine)

        #expect(throws: ContainerizationError.self) {
            try attach(label, token: "owner-b")
        }
        #expect(InstanceEndpoints.endpoint(label: label) === mine)
        #expect(InstanceEndpoints.owner(label: label) == "owner-a")

        let replacement = endpoint()
        try attach(label, token: "owner-a", endpoint: replacement)
        #expect(InstanceEndpoints.endpoint(label: label) === replacement)
    }

    @Test("the payload PID cannot make a live publisher look dead")
    func payloadPIDIsNotPublisherIdentity() throws {
        let label = unique("runtime")
        let original = endpoint()
        let forged = attachMessage(
            label, token: "owner-a", payloadPID: deadPID(), endpoint: original)
        try InstanceAttachHarness.record(
            forged,
            peerPID: getpid(),
            authorizedPublisher: true,
            log: log)

        #expect(throws: ContainerizationError.self) {
            try attach(label, token: "owner-b")
        }
        #expect(InstanceEndpoints.endpoint(label: label) === original)
    }

    @Test("resolve hands an endpoint only to its owner")
    func resolveRequiresTheOwnersToken() throws {
        let label = unique("network")
        try attach(label, token: "boot-secret")

        #expect(throws: ContainerizationError.self) { _ = try resolve(label, token: nil) }
        #expect(throws: ContainerizationError.self) {
            _ = try resolve(label, token: "not-the-secret")
        }
        #expect(try resolve(label, token: "boot-secret") != nil)
    }

    @Test("a same-EUID hostile process cannot be the first grants-label publisher")
    func hostileFirstGrantPublisherIsRefused() throws {
        let label = HostDirectoryGrants.vendorLabel
        InstanceEndpoints.remove(label: label)
        defer { InstanceEndpoints.remove(label: label) }

        #expect(throws: ContainerizationError.self) {
            try attach(
                label,
                token: "attacker-chosen-token",
                authorizedPublisher: false)
        }
        #expect(InstanceEndpoints.endpoint(label: label) == nil)

        let authorized = endpoint()
        try attach(
            label,
            token: "signed-app-token",
            endpoint: authorized,
            authorizedPublisher: true)
        #expect(InstanceEndpoints.endpoint(label: label) === authorized)
    }

    @Test("an unauthorized process cannot replace the signed grants publisher")
    func unauthorizedGrantReplacementIsRefused() throws {
        let label = HostDirectoryGrants.vendorLabel
        InstanceEndpoints.remove(label: label)
        defer { InstanceEndpoints.remove(label: label) }
        let original = endpoint()
        try attach(
            label,
            token: "signed-app-token",
            endpoint: original,
            authorizedPublisher: true)

        for token in ["signed-app-token", "attacker-token"] {
            #expect(throws: ContainerizationError.self) {
                try attach(
                    label,
                    token: token,
                    authorizedPublisher: false)
            }
        }
        #expect(InstanceEndpoints.endpoint(label: label) === original)
    }

    @Test("an embedder grant listener cannot be resolved by a same-user process")
    func embedderLabelIsPrivateToItsPublisher() throws {
        let label = unique("grants")
        let embedderToken = UUID().uuidString
        try attach(label, token: embedderToken)

        for token in ["apiserver-boot-token", "guess", ""] {
            #expect(throws: ContainerizationError.self) { _ = try resolve(label, token: token) }
            #expect(throws: ContainerizationError.self) { try attach(label, token: token) }
        }
        #expect(InstanceEndpoints.owner(label: label) == embedderToken)
    }

    @Test("a label whose authenticated peer exited can be taken by a successor")
    func deadPublisherLabelIsTakenOver() throws {
        let label = unique("grants")
        try attach(label, token: "old-app-token", peerPID: deadPID())
        let successor = endpoint()
        try attach(label, token: "new-app-token", endpoint: successor)
        #expect(InstanceEndpoints.endpoint(label: label) === successor)
        #expect(InstanceEndpoints.owner(label: label) == "new-app-token")
    }

    @Test("a live peer's label is not taken by a different token")
    func livePublisherLabelIsKept() throws {
        let label = unique("grants")
        let mine = endpoint()
        try attach(label, token: "live-app-token", endpoint: mine)
        #expect(throws: ContainerizationError.self) {
            try attach(label, token: "impostor")
        }
        #expect(InstanceEndpoints.endpoint(label: label) === mine)
    }

    @Test("bulk grants require both the signed app and current endpoint owner token")
    func bulkGrantPublicationIsBoundToSignedOwner() {
        let message = XPCMessage(route: XPCRoute.hostDirectoryGrantsPublish.rawValue)
        message.set(key: InstanceAttach.tokenKey, value: "current-app-token")

        #expect(
            HostDirectoryGrantHarness.authorized(
                message, peerIsHostApp: true, ownerToken: "current-app-token"))
        #expect(
            !HostDirectoryGrantHarness.authorized(
                message, peerIsHostApp: false, ownerToken: "current-app-token"))
        #expect(
            !HostDirectoryGrantHarness.authorized(
                message, peerIsHostApp: true, ownerToken: "replacement-token"))
        #expect(
            !HostDirectoryGrantHarness.authorized(
                message, peerIsHostApp: true, ownerToken: nil))
    }

    @Test("host signing policy requires the exact bundle identifier and team")
    func hostSigningPolicyIsExact() {
        let expected = HostAppPeerIdentity.SigningIdentity(
            identifier: "dev.thiagogonzaga.SiliconShip",
            teamIdentifier: "TEAM123")
        #expect(
            HostAppPeerIdentity.matches(
                expected,
                expectedIdentifier: "dev.thiagogonzaga.SiliconShip",
                expectedTeamIdentifier: "TEAM123"))
        #expect(
            !HostAppPeerIdentity.matches(
                .init(identifier: expected.identifier, teamIdentifier: "ATTACKER"),
                expectedIdentifier: expected.identifier,
                expectedTeamIdentifier: expected.teamIdentifier))
        #expect(
            !HostAppPeerIdentity.matches(
                .init(identifier: "dev.example.Impostor", teamIdentifier: expected.teamIdentifier),
                expectedIdentifier: expected.identifier,
                expectedTeamIdentifier: expected.teamIdentifier))
    }

    @Test("a resolve for an unknown label returns no endpoint")
    func unknownLabelResolvesToNothing() throws {
        #expect(try resolve(unique("nobody"), token: "any") == nil)
    }

    @Test("the process token is stable, private and unguessable in shape")
    func ownerTokenShape() {
        let token = InstanceAttach.ownerToken
        #expect(token == InstanceAttach.ownerToken)
        #expect(
            token.count == 64
                || ProcessInfo.processInfo.environment[InstanceAttach.tokenEnvironmentName] != nil)
    }
}
