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
import NIOHTTP1
import Testing

@testable import RegistryTransport

/// A push over plain HTTP with a credential, as Docker pushes to a registry on loopback: the
/// credential reaches that registry and no other.
@Suite("Explicit HTTP registry push", .timeLimit(.minutes(1)))
struct ExplicitHTTPPushTests {
    static let username = "m534user"
    static let password = "m534-pw-not-for-logs"
    static var basic: String { "Basic " + Data("\(username):\(password)".utf8).base64EncodedString() }

    /// A one-platform image in a store of its own: a layer, its config, the manifest and the
    /// index that names it.
    struct TinyImage {
        let root: URL
        let contentStore: LocalContentStore
        let index: Descriptor
        let blobs: [String]

        static func make() async throws -> TinyImage {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("m534-push-\(UUID().uuidString)")
            let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
            let (session, directory) = try await contentStore.newIngestSession()
            func put(_ bytes: [UInt8], _ mediaType: String, platform: Platform? = nil) throws -> Descriptor {
                let digest = MemoryRegistry.digest(bytes)
                try Data(bytes).write(to: directory.appendingPathComponent(String(digest.dropFirst("sha256:".count))))
                return Descriptor(mediaType: mediaType, digest: digest, size: Int64(bytes.count), platform: platform)
            }
            let layer = try put((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) }, MediaTypes.imageLayerGzip)
            let config = try put(
                Array(#"{"architecture":"arm64","os":"linux","rootfs":{"type":"layers","diff_ids":["\#(layer.digest)"]}}"#.utf8), MediaTypes.imageConfig)
            let manifest = try put(
                Array(try JSONEncoder().encode(Manifest(config: config, layers: [layer]))), MediaTypes.imageManifest,
                platform: Platform(arch: "arm64", os: "linux"))
            let index = try put(Array(try JSONEncoder().encode(Index(manifests: [manifest]))), MediaTypes.index)
            _ = try await contentStore.completeIngestSession(session)
            return TinyImage(root: root, contentStore: contentStore, index: index, blobs: [layer.digest, config.digest])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func client(_ registry: MemoryRegistry, password: String = Self.password) -> ExplicitHTTPRegistryClient {
        ExplicitHTTPRegistryClient(
            host: registry.host, port: registry.port, authentication: BasicAuthentication(username: username, password: password))
    }

    static func push(_ image: TinyImage, with client: ExplicitHTTPRegistryClient) async throws {
        let operation = ImageStore.ExportOperation(name: "m534/alpine", tag: "1", contentStore: image.contentStore, client: client)
        try await operation.export(index: image.index, platforms: { _ in true })
    }

    @Test("an image goes to a loopback registry with its credential on every request, and comes back whole")
    func pushAndPullBack() async throws {
        let image = try await TinyImage.make()
        defer { image.remove() }
        try await MemoryRegistry.serving(username: Self.username, password: Self.password) { registry in
            try await Self.push(image, with: Self.client(registry))

            #expect(registry.manifestDigest("m534/alpine", "1") == image.index.digest)
            for blob in image.blobs { #expect(registry.hasBlob(blob)) }
            let requests = registry.requests
            #expect(requests.contains { $0.method == .PUT && $0.uri.contains("/blobs/uploads/") && $0.uri.contains("_state=") && $0.uri.contains("digest=sha256") })
            #expect(requests.allSatisfy { $0.authorization == Self.basic }, "\(requests)")
            #expect(requests.allSatisfy { !$0.uri.contains(Self.password) })
            // The tag is put once, for the index; the image manifest goes under its digest.
            #expect(requests.filter { $0.method == .PUT && $0.uri.hasSuffix("/manifests/1") }.count == 1)

            // A second push finds everything there and uploads nothing.
            let before = requests.count
            try await Self.push(image, with: Self.client(registry))
            #expect(registry.requests.dropFirst(before).allSatisfy { $0.method == .HEAD }, "\(registry.requests.dropFirst(before))")

            // And the same transport pulls it back.
            let client = Self.client(registry)
            let root = try await client.resolve(name: "m534/alpine", tag: "1")
            #expect(root.digest == image.index.digest)
            let target = try LocalContentStore(path: image.root.appendingPathComponent("pulled"))
            let (session, directory) = try await target.newIngestSession()
            let pulled = try await ImageStore.ImportOperation(name: "m534/alpine", contentStore: target, client: client, ingestDir: directory)
                .import(root: root, matcher: createPlatformMatcher(for: nil))
            _ = try await target.completeIngestSession(session)
            #expect(pulled.digest == image.index.digest)
            for blob in image.blobs { #expect(try await target.get(digest: blob) != nil) }
        }
    }

    @Test("an upload location on the registry's own origin is followed")
    func absoluteLocation() async throws {
        let image = try await TinyImage.make()
        defer { image.remove() }
        try await MemoryRegistry.serving(username: Self.username, password: Self.password, location: .absolute) { registry in
            try await Self.push(image, with: Self.client(registry))
            #expect(registry.manifestDigest("m534/alpine", "1") == image.index.digest)
        }
    }

    @Test("an upload location on another origin stops the push before any content is sent")
    func otherOriginLocation() async throws {
        let image = try await TinyImage.make()
        defer { image.remove() }
        try await MemoryRegistry.serving(username: Self.username, password: Self.password, location: .otherOrigin) { registry in
            await #expect(throws: ExplicitHTTPRegistryClient.TransportPolicyError.crossOriginUpload) {
                try await Self.push(image, with: Self.client(registry))
            }
            #expect(!registry.requests.contains { $0.method == .PUT })
            // Control: the uploads were asked for, so the stop is the location's.
            #expect(registry.requests.contains { $0.method == .POST })
        }
    }

    @Test("a wrong password is the registry's refusal, which names no secret")
    func wrongPassword() async throws {
        let image = try await TinyImage.make()
        defer { image.remove() }
        try await MemoryRegistry.serving(username: Self.username, password: Self.password) { registry in
            let error = await #expect(throws: RegistryClient.Error.self) {
                try await Self.push(image, with: Self.client(registry, password: "wrong-pw-m534"))
            }
            guard case .invalidStatus(_, let status, _) = error else {
                Issue.record("expected the registry's status, got \(String(describing: error))")
                return
            }
            #expect(status == .unauthorized)
            #expect(!"\(String(describing: error))".contains("wrong-pw-m534"))
            #expect(registry.manifestDigest("m534/alpine", "1") == nil)
        }
    }

    @Test(
        "a push to a registry off loopback is refused before any request, its credential unsent",
        arguments: ["192.0.2.1", "10.0.0.1", "192.168.1.10", "registry.example", "localhost.example.com", "fd00::1"])
    func offLoopback(host: String) async throws {
        let image = try await TinyImage.make()
        defer { image.remove() }
        let client = ExplicitHTTPRegistryClient(host: host, port: 5000, authentication: BasicAuthentication(username: Self.username, password: Self.password))
        let started = ContinuousClock.now
        let error = await #expect(throws: ExplicitHTTPRegistryClient.TransportPolicyError.self) {
            try await Self.push(image, with: client)
        }
        #expect(error == .pushOffLoopback(host: host))
        #expect(error?.description.contains(Self.password) == false)
        // Refused here, not by a connection that timed out.
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test(
        "an upload location keeps its path and query on the client's origin; any other origin is refused",
        arguments: [
            ("/v2/a/blobs/uploads/1?_state=x", "/v2/a/blobs/uploads/1", "_state=x", true),
            ("http://127.0.0.1:5000/v2/a/blobs/uploads/1?_state=x", "/v2/a/blobs/uploads/1", "_state=x", true),
            ("HTTP://127.0.0.1:5000/v2/a/blobs/uploads/1", "/v2/a/blobs/uploads/1", nil, true),
            ("http://127.0.0.2:5000/v2/a/blobs/uploads/1", nil, nil, false),
            ("http://127.0.0.1:5001/v2/a/blobs/uploads/1", nil, nil, false),
            ("https://127.0.0.1:5000/v2/a/blobs/uploads/1", nil, nil, false),
            ("//registry.example/v2/a/blobs/uploads/1", nil, nil, false),
            ("http://registry.example/v2/a/blobs/uploads/1", nil, nil, false),
        ])
    func uploadTarget(location: String, path: String?, query: String?, allowed: Bool) throws {
        let client = ExplicitHTTPRegistryClient(host: "127.0.0.1", port: 5000, authentication: BasicAuthentication(username: "u", password: "p"))
        if allowed {
            let target = try client.uploadTarget(location)
            #expect(target.path == path)
            #expect(target.percentEncodedQuery == query)
            #expect(target.host == nil)
        } else {
            #expect(throws: ExplicitHTTPRegistryClient.TransportPolicyError.crossOriginUpload) { try client.uploadTarget(location) }
        }
    }

    @Test(
        "an index goes under the tag, or under its own digest when the push names a digest; an image manifest always under its digest",
        arguments: [
            (MediaTypes.index, "1", "1"), (MediaTypes.dockerManifestList, "latest", "latest"), (MediaTypes.index, "", "sha256:abc"),
            (MediaTypes.index, "sha256:def", "sha256:abc"), (MediaTypes.index, "1@sha256:abc", "sha256:abc"),
            (MediaTypes.imageManifest, "1", "sha256:abc"), (MediaTypes.dockerManifest, "latest", "sha256:abc"),
        ])
    func manifestObject(mediaType: String, tag: String, expected: String) {
        let descriptor = Descriptor(mediaType: mediaType, digest: "sha256:abc", size: 1)
        #expect(ExplicitHTTPRegistryClient.manifestObject(tag: tag, descriptor: descriptor) == expected)
    }

    @Test("an IPv6 loopback registry is addressed in brackets")
    func ipv6Origin() async throws {
        let client = try ExplicitHTTPRegistryClient(reference: "[::1]:5000/m534/alpine:1", authentication: BasicAuthentication(username: "u", password: "p"))
        let request = try await client.makeRequest(path: "/v2/")
        #expect(request.url == "http://[::1]:5000/v2/")
        #expect(try client.uploadTarget("http://[::1]:5000/v2/a/blobs/uploads/1").path == "/v2/a/blobs/uploads/1")
        #expect(throws: ExplicitHTTPRegistryClient.TransportPolicyError.crossOriginUpload) { try client.uploadTarget("http://[::2]:5000/v2/a") }
        let bare = ExplicitHTTPRegistryClient(host: "::1", port: nil, authentication: BasicAuthentication(username: "u", password: "p"))
        #expect(try await bare.makeRequest(path: "/v2/").url == "http://[::1]/v2/")
    }
}
