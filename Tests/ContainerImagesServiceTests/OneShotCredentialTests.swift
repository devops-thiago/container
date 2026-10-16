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

import ContainerImagesServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import ContainerImagesService

/// A credential sent with one pull, push or check: it is what reaches the registry, the
/// logins the engine keeps are not looked up at all, and nothing is kept.
@Suite(.timeLimit(.minutes(1)))
struct OneShotCredentialTests {
    /// A keychain that records: what was looked up and what was kept.
    final class Keychain: Sendable {
        private let state = Mutex<(lookups: [String], kept: [String], answer: BasicAuthentication?)>(([], [], nil))

        init(answer: BasicAuthentication? = nil) {
            state.withLock { $0.answer = answer }
        }

        var lookups: [String] { state.withLock { $0.lookups } }
        var kept: [String] { state.withLock { $0.kept } }

        func access(check: @escaping @Sendable ((host: String, port: Int?, scheme: String), BasicAuthentication) async throws -> Void = { _, _ in })
            -> RegistryAccess
        {
            RegistryAccess(
                check: check,
                keep: { [self] host, _, _ in state.withLock { $0.kept.append(host) } },
                forget: { _ in },
                lookup: { [self] host in
                    state.withLock { state in
                        state.lookups.append(host)
                        return state.answer
                    }
                })
        }
    }

    /// A plain-HTTP registry on loopback that refuses everything with 401 and records the
    /// `Authorization` each request carried.
    final class RecordingRegistry: Sendable {
        final class Seen: Sendable {
            let values = Mutex<[String]>([])
        }

        let port: Int
        private let channel: any Channel
        private let seen: Seen

        var authorizations: [String] { seen.values.withLock { $0 } }

        private init(channel: any Channel, seen: Seen) {
            self.channel = channel
            self.seen = seen
            self.port = channel.localAddress?.port ?? 0
        }

        static func start() async throws -> RecordingRegistry {
            let seen = Seen()
            let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(Handler(seen: seen))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            return RecordingRegistry(channel: channel, seen: seen)
        }

        func stop() async {
            try? await channel.close().get()
        }

        private final class Handler: ChannelInboundHandler, Sendable {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart
            let seen: Seen

            init(seen: Seen) { self.seen = seen }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard case .head(let head) = unwrapInboundIn(data) else { return }
                seen.values.withLock { $0.append(head.headers.first(name: "Authorization") ?? "") }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: .unauthorized, headers: headers))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    private func service(_ registry: RegistryAccess) throws -> (ImagesService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("one-shot-\(UUID().uuidString)")
        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: root.appendingPathComponent("images"), contentStore: contentStore)
        let snapshotStore = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        let service = try ImagesService(
            contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore,
            log: Logger(label: "one-shot-credential-tests"), registry: registry)
        return (service, root)
    }

    private static func basic(_ username: String, _ password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    @Test("the request's credential comes first and the kept login is not looked up; without one, the kept login is used")
    func precedence() async throws {
        let keychain = Keychain(answer: BasicAuthentication(username: "kept", password: "kept-pw"))
        let lookup = keychain.access().lookup

        let (sent, source) = try ImagesService.authentication(
            host: "registry.example", credential: RegistryCredential(username: "ana", password: "pw"), lookup: lookup)
        #expect(source == .request)
        #expect(try await sent?.token() == Self.basic("ana", "pw"))
        #expect(keychain.lookups.isEmpty, "the kept login was looked up although the request brought one")

        // Control: without a credential the kept login is what signs in.
        let (kept, keptSource) = try ImagesService.authentication(host: "registry.example", credential: nil, lookup: lookup)
        #expect(keptSource == .kept)
        #expect(try await kept?.token() == Self.basic("kept", "kept-pw"))
        #expect(keychain.lookups == ["registry.example"])

        // And with neither, there is none.
        let (none, noneSource) = try ImagesService.authentication(host: "registry.example", credential: nil, lookup: Keychain().access().lookup)
        #expect(none == nil)
        #expect(noneSource == .none)
    }

    @Test("a keychain that fails is not reached by a request that brought its credential")
    func failingKeychainNotReached() throws {
        struct Broken: Error {}
        let failing: @Sendable (String) throws -> (any Authentication)? = { _ in throw Broken() }
        let (_, source) = try ImagesService.authentication(host: "h", credential: RegistryCredential(username: "a", password: "b"), lookup: failing)
        #expect(source == .request)
        // Control: without one, the keychain's failure is the pull's.
        #expect(throws: Broken.self) { try ImagesService.authentication(host: "h", credential: nil, lookup: failing) }
    }

    @Test("a pull's credential is what reaches the registry, the kept login is not looked up, and nothing is kept")
    func pullCarriesTheCredential() async throws {
        let registry = try await RecordingRegistry.start()
        let keychain = Keychain(answer: BasicAuthentication(username: "kept", password: "kept-pw"))
        let (service, root) = try service(keychain.access())
        defer { try? FileManager.default.removeItem(at: root) }

        let reference = "127.0.0.1:\(registry.port)/team/app:1"
        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await service.pull(
                reference: reference, platform: nil, insecure: true, progressUpdate: nil,
                credential: RegistryCredential(username: "ana", password: "one-shot-pw"))
        }
        #expect(registry.authorizations.contains(Self.basic("ana", "one-shot-pw")), "seen: \(registry.authorizations)")
        #expect(!registry.authorizations.contains(Self.basic("kept", "kept-pw")))
        #expect(keychain.lookups.isEmpty)
        #expect(keychain.kept.isEmpty)
        // The refusal names the credential the request sent, not the engine's saved login.
        #expect(error?.message.contains("rejected the credential sent with the request") == true, "\(String(describing: error))")
        #expect(error.map { "\($0)" }?.contains("one-shot-pw") == false)

        // Control: the same pull without a credential signs in with the kept login.
        let control = await #expect(throws: ContainerizationError.self) {
            _ = try await service.pull(reference: reference, platform: nil, insecure: true, progressUpdate: nil)
        }
        #expect(registry.authorizations.last == Self.basic("kept", "kept-pw"))
        #expect(keychain.lookups == ["127.0.0.1:\(registry.port)"])
        #expect(keychain.kept.isEmpty)
        #expect(control?.message.contains("rejected the saved login") == true, "\(String(describing: control))")
        await registry.stop()
    }

    @Test("a push with a credential does not look up the kept login")
    func pushSkipsTheKeptLogin() async throws {
        let keychain = Keychain(answer: BasicAuthentication(username: "kept", password: "kept-pw"))
        let (service, root) = try service(keychain.access())
        defer { try? FileManager.default.removeItem(at: root) }

        // Nothing is here to push, so the push fails before it reaches a registry.
        await #expect(throws: (any Error).self) {
            try await service.push(
                reference: "127.0.0.1:9/team/app:1", platform: nil, insecure: true, progressUpdate: nil,
                credential: RegistryCredential(username: "ana", password: "pw"))
        }
        #expect(keychain.lookups.isEmpty)
        #expect(keychain.kept.isEmpty)
        // Control: without one, the push looks the kept login up.
        await #expect(throws: (any Error).self) {
            try await service.push(reference: "127.0.0.1:9/team/app:1", platform: nil, insecure: true, progressUpdate: nil)
        }
        #expect(keychain.lookups == ["127.0.0.1:9"])
    }

    @Test("a check answers what the registry said and keeps nothing")
    func checkKeepsNothing() async throws {
        let checked = Mutex<[(String, String)]>([])
        let keychain = Keychain()
        let (service, root) = try service(
            keychain.access(check: { target, _ in
                checked.withLock { $0.append((target.host, target.scheme)) }
            }))
        defer { try? FileManager.default.removeItem(at: root) }

        let answer = try await service.checkLogin(server: "registry.example:5000", credential: RegistryCredential(username: "ana", password: "pw"), scheme: "https")
        #expect(answer == .accepted)
        #expect(checked.withLock { $0.map(\.0) } == ["registry.example"])
        #expect(keychain.kept.isEmpty)
        #expect(keychain.lookups.isEmpty)

        // Control: a login with the same answer does keep it.
        try await service.login(server: "registry.example:5000", username: "ana", password: "pw", scheme: "https")
        #expect(keychain.kept == ["registry.example:5000"])
    }

    @Test("a refusal is the registry's status, and any other failure is an error", arguments: [401, 403])
    func checkRefused(status: Int) async throws {
        let keychain = Keychain()
        let (service, root) = try service(
            keychain.access(check: { _, _ in
                throw RegistryClient.Error.invalidStatus(url: "https://registry.example/v2/", HTTPResponseStatus(statusCode: status), reason: nil)
            }))
        defer { try? FileManager.default.removeItem(at: root) }
        let answer = try await service.checkLogin(server: "registry.example", credential: RegistryCredential(username: "ana", password: "bad"), scheme: "https")
        #expect(answer == .rejected(status: status))
        #expect(keychain.kept.isEmpty)
    }

    @Test("a check that cannot reach the registry is an error, not a refusal")
    func checkUnreachable() async throws {
        let (service, root) = try service(
            Keychain().access(check: { _, _ in
                throw RegistryClient.Error.invalidStatus(url: "https://registry.example/v2/", .badGateway, reason: nil)
            }))
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: RegistryClient.Error.self) {
            _ = try await service.checkLogin(server: "registry.example", credential: RegistryCredential(username: "a", password: "b"), scheme: "https")
        }
    }

    @Test("a check during a sign-in for the same host does not replace it: the sign-in still keeps its login")
    func checkDoesNotSupersedeALogin() async throws {
        let gate = Gate()
        let keychain = Keychain()
        let (service, root) = try service(
            keychain.access(check: { _, authentication in
                // Only the sign-in's check is held.
                if (try? await authentication.token()) == Self.basic("ana", "login-pw") { await gate.wait() }
            }))
        defer { try? FileManager.default.removeItem(at: root) }

        let login = Task { try await service.login(server: "ghcr.io", username: "ana", password: "login-pw", scheme: "https") }
        await gate.arrived()
        #expect(try await service.checkLogin(server: "ghcr.io", credential: RegistryCredential(username: "ana", password: "check-pw"), scheme: "https") == .accepted)
        gate.open()
        try await login.value
        #expect(keychain.kept == ["ghcr.io"])

        // Control: a second sign-in in the same place does replace the first, which keeps nothing.
        let held = Gate()
        let controlKeychain = Keychain()
        let (control, controlRoot) = try self.service(
            controlKeychain.access(check: { _, authentication in
                if (try? await authentication.token()) == Self.basic("ana", "login-pw") { await held.wait() }
            }))
        defer { try? FileManager.default.removeItem(at: controlRoot) }
        let first = Task { try await control.login(server: "ghcr.io", username: "ana", password: "login-pw", scheme: "https") }
        await held.arrived()
        try await control.login(server: "ghcr.io", username: "ana", password: "other-pw", scheme: "https")
        held.open()
        await #expect(throws: ContainerizationError.self) { try await first.value }
        #expect(controlKeychain.kept == ["ghcr.io"])
    }

    @Test("the harness passes a pull's credential on, and refuses one it cannot read without pulling")
    func harnessDecodesTheCredential() async throws {
        let registry = try await RecordingRegistry.start()
        let keychain = Keychain()
        let (service, root) = try service(keychain.access())
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = ImagesServiceHarness(service: service, log: Logger(label: "one-shot-credential-tests"))

        let pull = XPCMessage(route: .imagePull)
        pull.set(key: .imageReference, value: "127.0.0.1:\(registry.port)/team/app:1")
        pull.set(key: .insecureFlag, value: true)
        pull.set(key: .maxConcurrentDownloads, value: Int64(1))
        try pull.set(credential: RegistryCredential(username: "ana", password: "harness-pw"))
        await #expect(throws: (any Error).self) { _ = try await harness.pull(pull) }
        #expect(registry.authorizations.contains(Self.basic("ana", "harness-pw")))

        // Control: a credential that does not decode stops the pull before any request.
        let before = registry.authorizations.count
        let garbled = XPCMessage(route: .imagePull)
        garbled.set(key: .imageReference, value: "127.0.0.1:\(registry.port)/team/app:1")
        garbled.set(key: .insecureFlag, value: true)
        garbled.set(key: .maxConcurrentDownloads, value: Int64(1))
        garbled.set(key: .registryCredential, value: Data("not json".utf8))
        let error = await #expect(throws: ContainerizationError.self) { _ = try await harness.pull(garbled) }
        #expect(error?.code == .invalidArgument)
        #expect(registry.authorizations.count == before)
        #expect(keychain.lookups.isEmpty)
        await registry.stop()
    }

    /// A reply needs a message that came over a connection, so what the harness answers is
    /// covered through the service; here, what it refuses before it asks the registry.
    @Test("the harness refuses a check that brings no credential, without asking the registry")
    func harnessCheckNeedsACredential() async throws {
        let asked = Mutex(0)
        let (service, root) = try service(Keychain().access(check: { _, _ in asked.withLock { $0 += 1 } }))
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = ImagesServiceHarness(service: service, log: Logger(label: "one-shot-credential-tests"))
        let bare = XPCMessage(route: .registryCheck)
        bare.set(key: .registryServer, value: "registry.example")
        bare.set(key: .registryScheme, value: "https")
        let error = await #expect(throws: ContainerizationError.self) { _ = try await harness.registryCheck(bare) }
        #expect(error?.message == "missing registry credential")
        #expect(asked.withLock { $0 } == 0)
    }

    @Test("printing a credential shows none of it")
    func redacted() {
        let credential = RegistryCredential(username: "ana-user", password: "secret-pw")
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(reflecting: credential), dumped, "\([credential])"] {
            #expect(!text.contains("secret-pw"), "\(text)")
            #expect(!text.contains("ana-user"), "\(text)")
        }
        // Control: the value is still there to use.
        #expect(credential.password == "secret-pw")
    }
}

/// Holds one task until it is opened.
final class Gate: Sendable {
    private let state = Mutex<(waiting: CheckedContinuation<Void, Never>?, open: Bool, arrived: Bool)>((nil, false, false))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                state.arrived = true
                if state.open { return true }
                state.waiting = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func arrived() async {
        while !state.withLock({ $0.arrived }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func open() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.open = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }
}
