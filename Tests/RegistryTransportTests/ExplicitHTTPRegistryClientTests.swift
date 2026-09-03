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

import ContainerizationOCI
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

    @Test func referenceInitializerKeepsTheResolvedHostAndPort() async throws {
        let client = try ExplicitHTTPRegistryClient(
            reference: "localhost:5500/private/image:latest",
            authentication: BasicAuthentication(username: "u", password: "p"))

        let request = try await client.makeRequest(path: "/v2/")
        #expect(request.url == "http://localhost:5500/v2/")
        #expect(request.headers.first(name: "Authorization") == "Basic dTpw")
    }
}
