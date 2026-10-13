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

import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import RegistryTransport
import Testing

@testable import ContainerImagesService

/// The images service's own sign-in and sign-out, with a registry the test holds and a
/// keychain that records: a login keeps its credential only while it is the newest change
/// for its host and within its deadline, whichever scheme it goes over.
struct RegistryLoginServiceTests {
    /// A registry whose answers the test releases one at a time, and a keychain that records.
    private final class Stand: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, any Error>] = []
        private var arrived: [(host: String, port: Int?, scheme: String)] = []
        private(set) var kept: [(host: String, username: String)] = []
        private(set) var forgotten: [String] = []
        private(set) var cancelled = 0

        var checks: [(host: String, port: Int?, scheme: String)] { lock.withLock { arrived } }
        var keptLogins: [(host: String, username: String)] { lock.withLock { kept } }
        var forgottenHosts: [String] { lock.withLock { forgotten } }
        var cancelledChecks: Int { lock.withLock { cancelled } }

        func access(deadline: Duration = .seconds(30)) -> RegistryAccess {
            RegistryAccess(
                check: { [self] target, _ in
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            lock.withLock {
                                arrived.append((target.host, target.port, target.scheme))
                                waiting.append(continuation)
                            }
                        }
                    } onCancel: {
                        let held = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                            cancelled += 1
                            defer { waiting.removeAll() }
                            return waiting
                        }
                        held.forEach { $0.resume(throwing: CancellationError()) }
                    }
                },
                keep: { [self] host, username, _ in lock.withLock { kept.append((host, username)) } },
                forget: { [self] host in lock.withLock { forgotten.append(host) } },
                deadline: deadline)
        }

        /// Wait until `count` checks are held.
        func held(_ count: Int) async {
            while lock.withLock({ waiting.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
        }

        /// Answer the oldest held check: the registry accepts, or refuses with `error`.
        func answer(_ error: (any Error)? = nil) {
            let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
            if let error { next?.resume(throwing: error) } else { next?.resume() }
        }
    }

    private func service(_ stand: Stand, deadline: Duration = .seconds(30)) throws -> (ImagesService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-login-\(UUID().uuidString)")
        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: root.appendingPathComponent("images"), contentStore: contentStore)
        let snapshotStore = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        let service = try ImagesService(
            contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore,
            log: Logger(label: "registry-login-service-tests"), registry: stand.access(deadline: deadline))
        return (service, root)
    }

    @Test("an accepted login is kept, over either scheme, for the host it names", arguments: ["https", "http"])
    func acceptedLoginIsKept(scheme: String) async throws {
        let stand = Stand()
        let (service, root) = try service(stand)
        defer { try? FileManager.default.removeItem(at: root) }

        async let login: Void = service.login(server: "registry.example:5000", username: "ana", password: "pw", scheme: scheme)
        await stand.held(1)
        stand.answer()
        try await login

        #expect(stand.checks.map(\.scheme) == [scheme])
        #expect(stand.checks.map(\.host) == ["registry.example"])
        #expect(stand.checks.map(\.port) == [5000])
        #expect(stand.keptLogins.map(\.host) == ["registry.example:5000"])
        #expect(stand.keptLogins.map(\.username) == ["ana"])
    }

    @Test("a sign-out while the registry has not answered leaves the login nothing to keep", arguments: ["https", "http"])
    func signOutDuringTheCheckKeepsNothing(scheme: String) async throws {
        let stand = Stand()
        let (service, root) = try service(stand)
        defer { try? FileManager.default.removeItem(at: root) }

        let login = Task { try await service.login(server: "ghcr.io", username: "ana", password: "old", scheme: scheme) }
        await stand.held(1)
        try await service.logout(server: "ghcr.io")
        stand.answer()

        let error = await #expect(throws: ContainerizationError.self) { try await login.value }
        #expect(error?.code == .cancelled)
        #expect(stand.forgottenHosts == ["ghcr.io"])
        #expect(stand.keptLogins.isEmpty, "the replaced login wrote its credential: \(stand.keptLogins)")
    }

    @Test("of two sign-ins for one host, the older one's late answer keeps nothing")
    func olderSignInKeepsNothing() async throws {
        let stand = Stand()
        let (service, root) = try service(stand)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = Task { try await service.login(server: "ghcr.io", username: "old-user", password: "old", scheme: "https") }
        await stand.held(1)
        let newer = Task { try await service.login(server: "ghcr.io", username: "new-user", password: "new", scheme: "https") }
        await stand.held(2)
        stand.answer()  // the older check answers first, after the newer one began
        stand.answer()

        let error = await #expect(throws: ContainerizationError.self) { try await older.value }
        #expect(error?.code == .cancelled)
        try await newer.value
        #expect(stand.keptLogins.map(\.username) == ["new-user"])
    }

    @Test("a check past its deadline is cancelled, reported as a timeout, and keeps nothing")
    func stalledCheckKeepsNothing() async throws {
        let stand = Stand()
        let (service, root) = try service(stand, deadline: .milliseconds(200))
        defer { try? FileManager.default.removeItem(at: root) }

        let error = await #expect(throws: ContainerizationError.self) {
            try await service.login(server: "ghcr.io", username: "ana", password: "pw", scheme: "https")
        }
        #expect(error?.code == .timeout)
        #expect(stand.cancelledChecks == 1)
        #expect(stand.keptLogins.isEmpty)
    }

    @Test("a registry that refuses the credential keeps nothing, and its error is passed on")
    func refusedLoginKeepsNothing() async throws {
        let stand = Stand()
        let (service, root) = try service(stand)
        defer { try? FileManager.default.removeItem(at: root) }

        let login = Task { try await service.login(server: "ghcr.io", username: "ana", password: "wrong", scheme: "https") }
        await stand.held(1)
        stand.answer(ContainerizationError(.invalidArgument, message: "401 unauthorized"))

        let error = await #expect(throws: ContainerizationError.self) { try await login.value }
        #expect(error?.code == .invalidArgument)
        #expect(stand.keptLogins.isEmpty)
    }
}
