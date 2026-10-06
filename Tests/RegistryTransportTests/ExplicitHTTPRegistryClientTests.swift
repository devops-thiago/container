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

// Copyright © 2026 Apple Inc. and the container project authors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import ContainerizationOCI
import Foundation
import NIOHTTP1
import Testing

@testable import RegistryTransport

@Suite("Explicit HTTP registry credentials")
struct ExplicitHTTPRegistryClientTests {
    @Test func requestTargetsOnlyTheSelectedPlaintextOriginWithPreemptiveBasicAuth() async throws {
        let client = ExplicitHTTPRegistryClient(
            host: "127.0.0.1",
            port: 5000,
            authentication: BasicAuthentication(username: "developer", password: "secret"))

        let request = try await client.makeRequest(path: "/v2/private/image/manifests/latest", method: .HEAD)
        #expect(request.url == "http://127.0.0.1:5000/v2/private/image/manifests/latest")
        #expect(request.method == .HEAD)
        #expect(request.headers.first(name: "Authorization") == "Basic ZGV2ZWxvcGVyOnNlY3JldA==")
        #expect(!request.url.contains("secret"))
    }

    @Test func credentialBearingRedirectsAreRejectedRatherThanFollowed() {
        do {
            try ExplicitHTTPRegistryClient.rejectRedirect(statusCode: 302)
            Issue.record("Expected the credential-bearing redirect to be rejected")
        } catch let error as ExplicitHTTPRegistryClient.TransportPolicyError {
            #expect(error.statusCode == 302)
            #expect(
                error.description
                    == "insecure HTTP registry redirected a credential-bearing request; transfer stopped (HTTP status 302)")
            #expect(!error.description.localizedCaseInsensitiveContains("location"))
        } catch {
            Issue.record("Expected TransportPolicyError, got \(type(of: error))")
        }

        #expect(throws: Never.self) {
            try ExplicitHTTPRegistryClient.rejectRedirect(statusCode: 200)
        }
    }

    private static func client(_ registry: ScriptedRegistry, bufferSize: Int = 64 * 1024, idle: Duration = .seconds(30)) -> ExplicitHTTPRegistryClient {
        ExplicitHTTPRegistryClient(
            host: registry.host, port: registry.port,
            authentication: BasicAuthentication(username: "u", password: "p"),
            bufferSize: bufferSize, idleTimeout: idle)
    }

    /// The registry's own word for a size set the ceiling; over plain HTTP anyone on the path
    /// could name gigabytes and have the helper hold them.
    @Test func aManifestLargerThanTheCeilingIsRefused() async throws {
        let body = [UInt8](repeating: 0x7b, count: 100_000)
        let registry = try ScriptedRegistry(.init(headers: [("Content-Type", "application/vnd.oci.image.manifest.v1+json")], body: body))
        defer { registry.stop() }
        let descriptor = Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "a", count: 64), size: Int64(body.count))
        await #expect {
            try await Self.client(registry, bufferSize: 64 * 1024).fetchData(name: "private/image", descriptor: descriptor)
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("larger than 65536 bytes") == true
        }
        // Within the ceiling the same answer is read whole.
        let small = try ScriptedRegistry(.init(headers: [("Content-Type", "application/vnd.oci.image.manifest.v1+json")], body: Array(body.prefix(1_000))))
        defer { small.stop() }
        let data = try await Self.client(small).fetchData(name: "private/image", descriptor: descriptor)
        #expect(data.count == 1_000)
    }

    /// The digest check afterwards rejected a blob that was not what its descriptor said, but
    /// only once the disk had taken it.
    @Test func aBlobLongerThanItsDescriptorIsRefusedBeforeTheSurplusIsWritten() async throws {
        let body = (0..<50_000).map { UInt8(truncatingIfNeeded: $0) }
        let registry = try ScriptedRegistry(.init(body: body))
        defer { registry.stop() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: "sha256:" + String(repeating: "b", count: 64), size: 20_000)
        await #expect {
            try await Self.client(registry).fetchBlob(name: "private/image", descriptor: descriptor, into: file, progress: nil)
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("more than the 20000 bytes") == true
        }
        let written = try Data(contentsOf: file).count
        #expect(written <= 20_000, "nothing past the descriptor's size reached the disk: \(written)")

        let exact = Descriptor(mediaType: "application/octet-stream", digest: descriptor.digest, size: Int64(body.count))
        let (received, _) = try await Self.client(registry).fetchBlob(name: "private/image", descriptor: exact, into: file, progress: nil)
        #expect(received == Int64(body.count))
    }

    /// A peer that goes quiet without closing held a pull for ever.
    @Test func aSilentRegistryEndsInATimeout() async throws {
        let body = [UInt8](repeating: 1, count: 10_000)
        let registry = try ScriptedRegistry(.init(body: body, sendOnly: 2_000))
        defer { registry.stop() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = Descriptor(mediaType: "application/octet-stream", digest: "sha256:" + String(repeating: "c", count: 64), size: Int64(body.count))
        let started = ContinuousClock.now
        await #expect {
            try await Self.client(registry, idle: .milliseconds(300)).fetchBlob(name: "private/image", descriptor: descriptor, into: file, progress: nil)
        } throws: { error in
            let failure = error as? ContainerizationError
            return failure?.code == .timeout && failure?.message.contains("sent nothing") == true
        }
        #expect(started.duration(to: .now) < .seconds(10), "the wait is the idle timeout, not for ever")
    }

    @Test func referenceInitializerKeepsTheResolvedHostAndPort() async throws {
        let client = try ExplicitHTTPRegistryClient(
            reference: "localhost:5500/private/image:latest",
            authentication: BasicAuthentication(username: "u", password: "p"))

        let request = try await client.makeRequest(path: "/v2/")
        #expect(request.url == "http://localhost:5500/v2/")
        #expect(request.headers.first(name: "Authorization") == "Basic dTpw")
    }
}
