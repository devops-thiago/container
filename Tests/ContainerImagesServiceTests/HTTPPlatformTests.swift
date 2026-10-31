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
import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import ContainerImagesService

@Suite(.timeLimit(.minutes(2)))
struct HTTPPlatformTests {
    static let password = "fixture-platform-password"
    static let authorization = "Basic " + Data("reader:\(password)".utf8).base64EncodedString()

    struct Resource: Sendable {
        let type: String
        let bytes: Data
        var digest: String { "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        var descriptor: Descriptor { Descriptor(mediaType: type, digest: digest, size: Int64(bytes.count)) }
    }

    /// A real HTTP registry. Metadata exists, but a missing/wrong credential gets a Basic
    /// challenge, as registry:2 does. There are deliberately no layer endpoints.
    final class Registry: Sendable {
        struct Request: Sendable {
            let path: String
            let authorization: String?
        }
        final class Seen: Sendable {
            let requests = Mutex<[Request]>([])
        }
        let port: Int
        let seen: Seen
        let channel: any Channel
        var requests: [Request] { seen.requests.withLock { $0 } }
        var reference: String { "127.0.0.1:\(port)/team/image:latest" }

        init(channel: any Channel, seen: Seen) {
            self.channel = channel
            self.seen = seen
            self.port = channel.localAddress?.port ?? 0
        }

        static func serving(
            root: Resource, config: Resource?, authorization: String? = HTTPPlatformTests.authorization,
            redirect: String? = nil, body: (Registry) async throws -> Void
        ) async throws {
            var resources = ["/v2/team/image/manifests/latest": root, "/v2/team/image/manifests/\(root.digest)": root]
            if let config { resources["/v2/team/image/blobs/\(config.digest)"] = config }
            let answers = resources
            let seen = Seen()
            let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(
                            Handler(resources: answers, authorization: authorization, redirect: redirect, seen: seen))
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            do {
                try await body(Registry(channel: channel, seen: seen))
                try await channel.close().get()
            } catch {
                try? await channel.close().get()
                throw error
            }
        }

        final class Handler: ChannelInboundHandler, Sendable {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart
            let resources: [String: Resource]
            let authorization: String?
            let redirect: String?
            let seen: Seen

            init(resources: [String: Resource], authorization: String?, redirect: String?, seen: Seen) {
                self.resources = resources
                self.authorization = authorization
                self.redirect = redirect
                self.seen = seen
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                guard case .head(let request) = unwrapInboundIn(data) else { return }
                let sent = request.headers.first(name: "Authorization")
                seen.requests.withLock { $0.append(Request(path: request.uri, authorization: sent)) }
                let resource = resources[request.uri]
                var headers = HTTPHeaders()
                let status: HTTPResponseStatus
                let bytes: Data
                if let authorization, sent != authorization {
                    status = .unauthorized
                    bytes = Data()
                    headers.add(name: "WWW-Authenticate", value: "Basic realm=\"platform-fixture\"")
                } else if let redirect {
                    status = .temporaryRedirect
                    bytes = Data()
                    headers.add(name: "Location", value: redirect)
                } else if let resource {
                    status = .ok
                    bytes = resource.bytes
                    headers.add(name: "Content-Type", value: resource.type)
                    headers.add(name: "Docker-Content-Digest", value: resource.digest)
                } else {
                    status = .notFound
                    bytes = Data()
                }
                headers.add(name: "Content-Length", value: String(bytes.count))
                context.write(wrapOutboundOut(.head(.init(version: request.version, status: status, headers: headers))), promise: nil)
                if request.method != .HEAD && !bytes.isEmpty {
                    context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: bytes)))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    private func service(at root: URL, credential: Bool = true, logger: Logger = Logger(label: "http-platform-tests")) throws -> ImagesService {
        let content = try LocalContentStore(path: root.appendingPathComponent("content"))
        let images = try ImageStore(path: root.appendingPathComponent("images"), contentStore: content)
        let snapshots = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        let keychain = OneShotCredentialTests.Keychain(
            answer: credential ? BasicAuthentication(username: "reader", password: Self.password) : nil)
        return try ImagesService(
            contentStore: content, imageStore: images, snapshotStore: snapshots,
            log: logger, registry: keychain.access())
    }

    private func metadata(_ type: String) throws -> (Resource, Resource?) {
        let docker = type == MediaTypes.dockerManifest || type == MediaTypes.dockerManifestList
        let config = Resource(
            type: docker ? MediaTypes.dockerImageConfig : MediaTypes.imageConfig,
            bytes: Data(#"{"architecture":"arm64","os":"linux","variant":"v8","rootfs":{"type":"layers","diff_ids":[]}}"#.utf8))
        if type == MediaTypes.imageManifest || type == MediaTypes.dockerManifest {
            let manifest = Manifest(
                mediaType: type, config: config.descriptor,
                layers: [
                    Descriptor(mediaType: docker ? MediaTypes.dockerImageLayerGzip : MediaTypes.imageLayerGzip, digest: "sha256:" + String(repeating: "a", count: 64), size: 1024)
                ])
            return (Resource(type: type, bytes: try JSONEncoder().encode(manifest)), config)
        }
        var manifests = [Platform(arch: "arm64", os: "linux", variant: "v8"), Platform(arch: "amd64", os: "linux")].map {
            Descriptor(mediaType: docker ? MediaTypes.dockerManifest : MediaTypes.imageManifest, digest: "sha256:" + String(repeating: "b", count: 64), size: 1024, platform: $0)
        }
        manifests.append(
            Descriptor(
                mediaType: MediaTypes.imageManifest, digest: "sha256:" + String(repeating: "c", count: 64), size: 1024,
                platform: Platform(arch: "unknown", os: "unknown")))
        manifests.append(
            Descriptor(
                mediaType: MediaTypes.imageManifest, digest: "sha256:" + String(repeating: "d", count: 64), size: 1024,
                annotations: ["vnd.docker.reference.type": "attestation-manifest"], platform: Platform(arch: "arm64", os: "linux")))
        return (Resource(type: type, bytes: try JSONEncoder().encode(Index(mediaType: type, manifests: manifests))), nil)
    }

    @Test(
        "saved HTTP login discovers image platforms without downloading layers",
        arguments: [
            MediaTypes.index, MediaTypes.dockerManifestList, MediaTypes.imageManifest, MediaTypes.dockerManifest,
        ], [false, true])
    func authenticatedPlatforms(type: String, byDigest: Bool) async throws {
        let (root, config) = try metadata(type)
        try await Registry.serving(root: root, config: config) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = try service(at: directory)
            let reference = byDigest ? "127.0.0.1:\(registry.port)/team/image@\(root.digest)" : registry.reference
            let platforms = try await service.platforms(reference: reference, insecure: true)
            if config == nil {
                #expect(platforms == [Platform(arch: "arm64", os: "linux", variant: "v8"), Platform(arch: "amd64", os: "linux")])
            } else {
                #expect(platforms == [Platform(arch: "arm64", os: "linux", variant: "v8")])
            }
            #expect(!registry.requests.isEmpty)
            #expect(registry.requests.allSatisfy { $0.authorization == Self.authorization })
            #expect(registry.requests.count == (config == nil ? 2 : 3), "only root metadata and optional config are fetched")
            #expect(!registry.requests.contains { $0.path.contains(String(repeating: "a", count: 64)) }, "no layers are downloaded")
        }
    }

    @Test("anonymous HTTP platform discovery still works without credentials")
    func anonymousPlatforms() async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config, authorization: nil) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let platforms = try await service(at: directory, credential: false).platforms(reference: registry.reference, insecure: true)
            #expect(platforms.count == 2)
            #expect(!registry.requests.isEmpty)
            #expect(registry.requests.allSatisfy { $0.authorization == nil })
        }
    }

    @Test("local platform metadata needs no registry request", arguments: [true, false])
    func localPlatforms(insecure: Bool) async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try await LoopbackHTTPPushTests.store(registry.reference, at: directory)
            let platforms = try await service(at: directory).platforms(reference: registry.reference, insecure: insecure)
            #expect(platforms == [Platform(arch: "arm64", os: "linux")])
            #expect(registry.requests.isEmpty)
        }
    }

    @Test("a failed HTTPS lookup never falls back to credential-bearing HTTP")
    func httpsDoesNotDowngrade() async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = try service(at: directory)
            // The server is deliberately HTTP-only: HTTPS must fail instead of probing
            // again in clear and handing it the saved credential.
            await #expect(throws: (any Error).self) {
                try await service.platforms(reference: registry.reference, insecure: false)
            }
            #expect(registry.requests.isEmpty, "no HTTP request or credential may follow a TLS failure")
        }
    }

    @Test("a refused credential is reported without its secret")
    func refusedCredential() async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config, authorization: "Basic refused") { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = LoopbackHTTPPushTests.CapturedLog()
            let service = try service(at: directory, logger: log.logger)
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.platforms(reference: registry.reference, insecure: true)
            }
            #expect(error?.code == .invalidState)
            #expect(error?.message.contains("rejected the saved login") == true)
            #expect(registry.requests.map(\.authorization) == [Self.authorization])
            let diagnostic = String(describing: error) + log.lines.withLock { $0.joined(separator: "\n") }
            #expect(!diagnostic.contains(Self.password) && !diagnostic.contains(Self.authorization))
        }
    }

    @Test("authenticated platform queries reject redirects without reaching their target")
    func redirectIsNotFollowed() async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config, authorization: nil) { target in
            try await Registry.serving(root: root, config: config, redirect: "http://127.0.0.1:\(target.port)/v2/team/image/manifests/latest") { registry in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let service = try service(at: directory)
                await #expect {
                    try await service.platforms(reference: registry.reference, insecure: true)
                } throws: { error in
                    String(describing: error).contains("redirected a credential-bearing request")
                        && !String(describing: error).contains(Self.password)
                }
                #expect(registry.requests.map(\.authorization) == [Self.authorization])
                #expect(target.requests.isEmpty)
            }
        }
    }

    @Test("unsupported platform metadata is rejected before fetching its body")
    func unsupportedMetadata() async throws {
        let root = Resource(type: "application/octet-stream", bytes: Data("unsupported".utf8))
        try await Registry.serving(root: root, config: nil) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = try service(at: directory)
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.platforms(reference: registry.reference, insecure: true)
            }
            #expect(error?.code == .unsupported)
            #expect(error?.message.contains("application/octet-stream") == true)
            #expect(registry.requests.count == 1)
        }
    }

    @Test("a reference without a tag or digest is rejected before contacting HTTP")
    func missingTag() async throws {
        let (root, config) = try metadata(MediaTypes.index)
        try await Registry.serving(root: root, config: config) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = try service(at: directory)
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.platforms(reference: "127.0.0.1:\(registry.port)/team/image", insecure: true)
            }
            #expect(error?.code == .invalidArgument)
            #expect(error?.message.contains("tag/digest") == true)
            #expect(registry.requests.isEmpty)
        }
    }

    @Test("platform discovery bounds both index and config bodies", arguments: [false, true])
    func oversizedMetadata(configBody: Bool) async throws {
        let oversized = Resource(
            type: configBody ? MediaTypes.imageConfig : MediaTypes.index,
            bytes: Data(repeating: 0x7b, count: 4 * 1_048_576 + 1))
        let root =
            configBody
            ? Resource(type: MediaTypes.imageManifest, bytes: try JSONEncoder().encode(Manifest(config: oversized.descriptor, layers: [])))
            : oversized
        try await Registry.serving(root: root, config: configBody ? oversized : nil) { registry in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("http-platform-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = try service(at: directory)
            await #expect {
                try await service.platforms(reference: registry.reference, insecure: true)
            } throws: { error in
                (error as? ContainerizationError)?.message.contains("larger than 4194304 bytes") == true
            }
            #expect(registry.requests.count == (configBody ? 3 : 2))
            #expect(registry.requests.allSatisfy { $0.authorization == Self.authorization })
        }
    }
}
