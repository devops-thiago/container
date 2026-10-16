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
import Containerization
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Synchronization
import Testing

@testable import ContainerImagesService

/// A push over the HTTP a caller selected carries its credential only to a registry on
/// loopback, as Docker pushes in clear only to `127.0.0.0/8` and `::1`.
@Suite(.timeLimit(.minutes(1)))
struct LoopbackHTTPPushTests {
    @Test(
        "a push with a login over HTTP takes the credential transport only to a registry on loopback",
        arguments: [
            ("localhost:5000/m534/alpine:1", true), ("localhost/m534/alpine:1", true), ("127.0.0.1:5000/m534/alpine:1", true),
            ("127.9.8.7/m534/alpine:1", true), ("[::1]:5000/m534/alpine:1", true),
            ("localhost.example.com:5000/m534/alpine:1", false), ("192.168.1.10:5000/m534/alpine:1", false),
            ("10.0.0.1:5000/m534/alpine:1", false), ("registry.example:5000/m534/alpine:1", false), ("[fd00::1]:5000/m534/alpine:1", false),
            ("ghcr.io/m534/alpine:1", false),
        ])
    func loopbackOnly(reference: String, loopback: Bool) {
        #expect(ImagesService.pushesOverExplicitHTTP(reference: reference, insecure: true, authenticated: true) == loopback)
        // Over HTTPS, or with no login to send, the upstream client pushes as before.
        #expect(!ImagesService.pushesOverExplicitHTTP(reference: reference, insecure: false, authenticated: true))
        #expect(!ImagesService.pushesOverExplicitHTTP(reference: reference, insecure: true, authenticated: false))
    }

    /// A log that keeps every line, metadata included.
    final class CapturedLog: Sendable {
        let lines = Mutex<[String]>([])

        var logger: Logger {
            var logger = Logger(label: "captured") { _ in Handler(log: self) }
            logger.logLevel = .trace
            return logger
        }

        struct Handler: LogHandler {
            let log: CapturedLog
            var metadata: Logger.Metadata = [:]
            var logLevel: Logger.Level = .trace

            subscript(metadataKey key: String) -> Logger.Metadata.Value? {
                get { metadata[key] }
                set { metadata[key] = newValue }
            }

            func log(event: LogEvent) {
                let all = metadata.merging(event.metadata ?? [:]) { _, new in new }
                let line = "\(event.level) \(event.message) \(all) \(event.error.map { "\($0)" } ?? "")"
                log.lines.withLock { $0.append(line) }
            }
        }
    }

    /// Puts a one-platform image under `reference` in a store at `root`.
    static func store(_ reference: String, at root: URL) async throws -> (LocalContentStore, ImageStore) {
        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: root.appendingPathComponent("images"), contentStore: contentStore)
        let (session, directory) = try await contentStore.newIngestSession()
        func put(_ bytes: [UInt8], _ mediaType: String, platform: Platform? = nil) throws -> Descriptor {
            let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try Data(bytes).write(to: directory.appendingPathComponent(hex))
            return Descriptor(mediaType: mediaType, digest: "sha256:\(hex)", size: Int64(bytes.count), platform: platform)
        }
        let layer = try put(Array(repeating: 0x5a, count: 512), MediaTypes.imageLayerGzip)
        let config = try put(Array(#"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8), MediaTypes.imageConfig)
        let manifest = try put(
            Array(try JSONEncoder().encode(Manifest(config: config, layers: [layer]))), MediaTypes.imageManifest, platform: Platform(arch: "arm64", os: "linux"))
        let index = try put(Array(try JSONEncoder().encode(Index(manifests: [manifest]))), MediaTypes.index)
        _ = try await contentStore.completeIngestSession(session)
        _ = try await imageStore.create(description: .init(reference: reference, descriptor: index))
        return (contentStore, imageStore)
    }

    @Test("a push with the request's credential to a loopback HTTP registry sends it there, and logs none of it")
    func loopbackPushCarriesTheCredential() async throws {
        let registry = try await OneShotCredentialTests.RecordingRegistry.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m534-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = "127.0.0.1:\(registry.port)/m534/alpine:1"
        let (contentStore, imageStore) = try await Self.store(reference, at: root)
        let snapshotStore = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        let captured = CapturedLog()
        let looked = Mutex<[String]>([])
        let service = try ImagesService(
            contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore, log: captured.logger,
            registry: RegistryAccess(
                check: { _, _ in }, keep: { _, _, _ in }, forget: { _ in },
                lookup: { host in
                    looked.withLock { $0.append(host) }
                    return nil
                }))

        let secret = "m534-one-shot-pw"
        let basic = "Basic " + Data("ana:\(secret)".utf8).base64EncodedString()
        // The recording registry refuses everything, so the push ends in that refusal.
        let error = await #expect(throws: ContainerizationError.self) {
            try await service.push(
                reference: reference, platform: nil, insecure: true, progressUpdate: nil, credential: RegistryCredential(username: "ana", password: secret))
        }
        #expect(registry.authorizations.first == basic, "the credential went out up front: \(registry.authorizations)")
        #expect(error?.message.contains("rejected the credential sent with the request") == true, "\(String(describing: error))")
        #expect(looked.withLock { $0.isEmpty })

        let log = captured.lines.withLock { $0.joined(separator: "\n") }
        #expect(log.contains("ImagesService: enter"), "positive control: the push was logged\n\(log)")
        for leak in [secret, basic, String(basic.dropFirst("Basic ".count))] {
            #expect(!log.contains(leak), "the log holds the credential:\n\(log)")
        }
        #expect(error.map { "\($0)" }?.contains(secret) == false)
        await registry.stop()
    }
}
