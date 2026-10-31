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

    @Test("Aliases from the network specification land on the attachment they were declared for")
    func testAttachmentConfigurationsCarryAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api.test", ".foo.test"]),
            Parser.ParsedNetwork(name: "backend"),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments.count == 2)
        #expect(attachments[0].network == "default")
        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].network == "backend")
        #expect(attachments[1].options.hostname == "foo")
        #expect(attachments[1].options.aliases.isEmpty)
    }

    @Test("Aliases are carried to a later attachment")
    func testAttachmentConfigurationsCarryAliasesOnLaterNetworks() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default"),
            Parser.ParsedNetwork(name: "backend", aliases: ["db.internal"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.aliases.isEmpty)
        #expect(attachments[1].options.aliases == ["db.internal"])
    }

    @Test("A container with no network specification has no aliases")
    func testDefaultAttachmentHasNoAliases() throws {
        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: [],
            dnsDomain: "test"
        )

        #expect(attachments.count == 1)
        #expect(attachments[0].options.aliases.isEmpty)
    }

    @Test("Aliases without a domain get the default domain")
    func testQualifyAliasesAddsTheDefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "test")

        #expect(aliases == ["api.test", ".gateway.test"])
    }

    @Test("Aliases with a dot are taken to be qualified")
    func testQualifyAliasesLeavesQualifiedNamesAlone() throws {
        let aliases = try Utility.qualifyAliases(["web.internal", ".a.b", "api.test"], dnsDomain: "test")

        #expect(aliases == ["web.internal", ".a.b", "api.test"])
    }

    @Test("Aliases are left as they are without a default domain")
    func testQualifyAliasesWithoutADefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway", "web.internal"], dnsDomain: nil)

        #expect(aliases == ["api", ".gateway", "web.internal"])
    }

    @Test("No aliases stay empty")
    func testQualifyAliasesWithNoAliases() throws {
        #expect(try Utility.qualifyAliases([], dnsDomain: "test").isEmpty)
        #expect(try Utility.qualifyAliases([], dnsDomain: nil).isEmpty)
    }

    @Test("The default domain is normalized when it is added")
    func testQualifyAliasesNormalizesTheDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "Example.TEST.")

        #expect(aliases == ["api.example.test", ".gateway.example.test"])
    }

    @Test("A default domain that is not a valid name is reported")
    func testQualifyAliasesWithAnInvalidDomain() {
        #expect(throws: (any Error).self) {
            try Utility.qualifyAliases(["api"], dnsDomain: "not a domain")
        }
    }

    @Test("Aliases in a network specification are qualified when the attachments are built")
    func testAttachmentConfigurationsQualifyAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api", ".foo"]),
            Parser.ParsedNetwork(name: "backend", aliases: ["db"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].options.aliases == ["db.test"])
    }
    private actor ImageStub {
        var calls: [String] = []
        var requests: [Utility.ImageRequest] = []
        var localError: ContainerizationError?
        var localConfig: ContainerSystemConfig?
        var progressCount = 0
        var indexError: ContainerizationError?
        var discoveryScheme: RequestScheme?

        init(localError: ContainerizationError? = nil, indexError: ContainerizationError? = nil) {
            self.localError = localError
            self.indexError = indexError
        }

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

        func platforms(_ reference: String, _ scheme: RequestScheme, _ config: ContainerSystemConfig) -> [Platform] {
            calls.append("platforms:" + reference)
            discoveryScheme = scheme
            localConfig = config
            return [.init(arch: "arm64", os: "linux")]
        }

        func localPlatforms(_ image: ClientImage) throws -> [Platform] {
            calls.append("index:" + image.digest)
            if let indexError { throw indexError }
            return [.init(arch: "arm64", os: "linux"), .init(arch: "amd64", os: "linux")]
        }

        nonisolated var client: Utility.ImageClient {
            .init(
                pull: { await self.remote("pull", $0) }, fetch: { await self.remote("fetch", $0) }, get: { try await self.local($0, $1) },
                platforms: { await self.platforms($0, $1, $2) }, localPlatforms: { try await self.localPlatforms($0) })
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

    @Test("never resolves platforms from the local index and reuses that image")
    func imagePullNeverLocalPlatforms() async throws {
        let stub = ImageStub()
        let config = ContainerSystemConfig()
        let result = try await Utility.imageCandidatesForCreate(
            policy: .never, reference: "localhost:5000/app:latest", scheme: .http, config: config, client: stub.client)
        #expect(result.platforms == [.init(arch: "arm64", os: "linux"), .init(arch: "amd64", os: "linux")])
        #expect(result.localImage?.digest == "sha256:cached")
        #expect(await stub.calls == ["get:localhost:5000/app:latest", "index:sha256:cached"])
        #expect(await stub.localConfig === config)
    }

    @Test("never refuses absent local images before remote platform discovery")
    func imagePullNeverMissingBeforePlatforms() async {
        let stub = ImageStub(localError: .init(.notFound, message: "local fixture absent"))
        do {
            _ = try await Utility.imageCandidatesForCreate(
                policy: .never, reference: "localhost:5000/app:latest", scheme: .http, config: .init(), client: stub.client)
            Issue.record("an absent image must fail before platform discovery")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.notFound))
            #expect(error.message.contains("--pull never"))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await stub.calls == ["get:localhost:5000/app:latest"])
    }

    @Test("never does not repair a missing local index through the registry")
    func imagePullNeverMissingLocalIndex() async {
        let stub = ImageStub(indexError: .init(.notFound, message: "index fixture absent"))
        do {
            _ = try await Utility.imageCandidatesForCreate(
                policy: .never, reference: "localhost:5000/app:latest", scheme: .http, config: .init(), client: stub.client)
            Issue.record("an incomplete local image must fail without a registry request")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.notFound))
            #expect(error.message.contains("--pull never"))
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await stub.calls == ["get:localhost:5000/app:latest", "index:sha256:cached"])
    }

    @Test("platform discovery preserves local storage errors under never")
    func imagePullNeverPlatformStoreFailure() async {
        let stub = ImageStub(localError: .init(.internalError, message: "store unavailable"))
        do {
            _ = try await Utility.imageCandidatesForCreate(
                policy: .never, reference: "localhost:5000/app:latest", scheme: .http, config: .init(), client: stub.client)
            Issue.record("storage failure must propagate")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.internalError))
            #expect(error.message == "store unavailable")
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(await stub.calls == ["get:localhost:5000/app:latest"])
    }

    @Test("always and missing retain registry-aware platform discovery", arguments: [Flags.ImageFetch.PullPolicy.always, .missing])
    func imagePullRemotePlatforms(policy: Flags.ImageFetch.PullPolicy) async throws {
        let stub = ImageStub()
        let config = ContainerSystemConfig()
        let result = try await Utility.imageCandidatesForCreate(
            policy: policy, reference: "localhost:5000/app:latest", scheme: .http, config: config, client: stub.client)
        #expect(result.platforms == [.init(arch: "arm64", os: "linux")])
        #expect(result.localImage == nil)
        #expect(await stub.calls == ["platforms:localhost:5000/app:latest"])
        #expect(await stub.discoveryScheme == .http)
        #expect(await stub.localConfig === config)
    }

}
