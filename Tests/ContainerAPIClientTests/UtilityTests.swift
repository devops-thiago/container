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

import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress
import Testing

@testable import ContainerAPIClient

struct UtilityTests {

    @Test("Parse simple key-value pairs")
    func testSimpleKeyValuePairs() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test("Parse standalone keys")
    func testStandaloneKeys() {
        let result = Utility.parseKeyValuePairs(["standalone"])

        #expect(result["standalone"] == "")
    }

    @Test("Parse empty input")
    func testEmptyInput() {
        let result = Utility.parseKeyValuePairs([])

        #expect(result.isEmpty)
    }

    @Test("Parse mixed format")
    func testMixedFormat() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "standalone", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["standalone"] == "")
        #expect(result["key2"] == "value2")
    }

    @Test("Valid MAC address with colons")
    func testValidMACAddressWithColons() throws {
        try Utility.validMACAddress("02:42:ac:11:00:02")
        try Utility.validMACAddress("AA:BB:CC:DD:EE:FF")
        try Utility.validMACAddress("00:00:00:00:00:00")
        try Utility.validMACAddress("ff:ff:ff:ff:ff:ff")
    }

    @Test("Valid MAC address with hyphens")
    func testValidMACAddressWithHyphens() throws {
        try Utility.validMACAddress("02-42-ac-11-00-02")
        try Utility.validMACAddress("AA-BB-CC-DD-EE-FF")
    }

    @Test("Invalid MAC address format")
    func testInvalidMACAddressFormat() {
        #expect(throws: Error.self) {
            try Utility.validMACAddress("invalid")
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00")  // Too short
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:02:03")  // Too long
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")  // Invalid hex
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:")  // Incomplete
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02.42.ac.11.00.02")  // Wrong separator
        }
    }

    @Test("Trim fully-qualified digest strips scheme and truncates to 12 chars")
    func testTrimDigestFullyQualified() {
        let hex = "0be69a25c33692845efb1e93f4254f28505a330896376bf8"
        #expect(Utility.trimDigest(digest: "sha256:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with unknown scheme strips scheme prefix")
    func testTrimDigestUnknownScheme() {
        let hex = "abcdef123456789012345678"
        #expect(Utility.trimDigest(digest: "blake3:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with no scheme truncates directly")
    func testTrimDigestNoScheme() {
        let hex = "abcdef1234567890"
        #expect(Utility.trimDigest(digest: hex) == String(hex.prefix(12)))
    }

    @Test("Trim digest shorter than 12 chars returns value unchanged")
    func testTrimDigestShort() {
        #expect(Utility.trimDigest(digest: "sha256:abc") == "abc")
    }

    @Test
    func testPublishPortParser() throws {
        let ports = try Parser.publishPorts([
            "127.0.0.1:8000:9080",
            "8080-8179:9000-9099/udp",
        ])
        #expect(ports.count == 2)
        #expect(ports[0].hostAddress.description == "127.0.0.1")
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9080)
        #expect(ports[0].proto == .tcp)
        #expect(ports[0].count == 1)
        #expect(ports[1].hostAddress.description == "0.0.0.0")
        #expect(ports[1].hostPort == 8080)
        #expect(ports[1].containerPort == 9000)
        #expect(ports[1].proto == .udp)
        #expect(ports[1].count == 100)
    }
    private actor ImageStub {
        var calls: [String] = []
        var requests: [Utility.ImageRequest] = []
        var localError: ContainerizationError?
        var localConfig: ContainerSystemConfig?
        var progressCount = 0

        init(localError: ContainerizationError? = nil) { self.localError = localError }

        nonisolated static func image(_ digest: String) -> ClientImage {
            ClientImage(
                description: .init(reference: "localhost:5000/app:latest", descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: digest, size: 0)))
        }

        func remote(_ operation: String, _ request: Utility.ImageRequest) async -> ClientImage {
            calls.append(operation)
            requests.append(request)
            await request.progress([.setDescription("pulling fresh manifest")])
            return Self.image(operation == "pull" ? "sha256:fresh" : "sha256:cached")
        }

        func local(_ reference: String, _ config: ContainerSystemConfig) throws -> ClientImage {
            calls.append("get:" + reference)
            localConfig = config
            if let localError { throw localError }
            return Self.image("sha256:cached")
        }

        func progress() { progressCount += 1 }

        nonisolated var client: Utility.ImageClient {
            .init(pull: { await self.remote("pull", $0) }, fetch: { await self.remote("fetch", $0) }, get: { try await self.local($0, $1) })
        }
    }

    private func imageRequest(_ stub: ImageStub, config: ContainerSystemConfig = .init()) -> Utility.ImageRequest {
        .init(
            reference: "localhost:5000/app:latest", platform: .init(arch: "arm64", os: "linux"), scheme: .http,
            config: config, progress: { _ in await stub.progress() }, maxConcurrentDownloads: 7)
    }

    @Test("always repulls a present tag and missing uses the cache-aware fetch")
    func imagePullPolicies() async throws {
        for (policy, operation, digest) in [(Flags.ImageFetch.PullPolicy.always, "pull", "sha256:fresh"), (.missing, "fetch", "sha256:cached")] {
            let stub = ImageStub()
            let config = ContainerSystemConfig()
            let image = try await Utility.imageForCreate(policy: policy, request: imageRequest(stub, config: config), client: stub.client)
            #expect(image.digest == digest)
            #expect(await stub.calls == [operation])
            let request = try #require(await stub.requests.first)
            #expect(request.reference == "localhost:5000/app:latest")
            #expect(request.platform == .init(arch: "arm64", os: "linux"))
            #expect(request.scheme == .http)
            #expect(request.config === config)
            #expect(request.maxConcurrentDownloads == 7)
            #expect(await stub.progressCount == 1)
        }
    }

    @Test("never returns the local image without a registry operation")
    func imagePullNeverPresent() async throws {
        let stub = ImageStub()
        let config = ContainerSystemConfig()
        let image = try await Utility.imageForCreate(policy: .never, request: imageRequest(stub, config: config), client: stub.client)
        #expect(image.digest == "sha256:cached")
        #expect(await stub.calls == ["get:localhost:5000/app:latest"])
        #expect(await stub.localConfig === config)
        #expect(await stub.progressCount == 0)
    }

    @Test("never reports a missing local image without trying a registry")
    func imagePullNeverMissing() async {
        let stub = ImageStub(localError: .init(.notFound, message: "absent fixture"))
        do {
            _ = try await Utility.imageForCreate(policy: .never, request: imageRequest(stub), client: stub.client)
            Issue.record("an absent image must fail under --pull never")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.notFound))
            #expect(error.message.contains("localhost:5000/app:latest"))
            #expect(error.message.contains("--pull never"))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await stub.calls == ["get:localhost:5000/app:latest"])
        #expect(await stub.progressCount == 0)
    }

    @Test("never preserves local store errors other than notFound")
    func imagePullNeverStoreFailure() async {
        let stub = ImageStub(localError: .init(.internalError, message: "store unavailable"))
        do {
            _ = try await Utility.imageForCreate(policy: .never, request: imageRequest(stub), client: stub.client)
            Issue.record("the local store error must propagate")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.internalError))
            #expect(error.message == "store unavailable")
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await stub.calls == ["get:localhost:5000/app:latest"])
    }

}
