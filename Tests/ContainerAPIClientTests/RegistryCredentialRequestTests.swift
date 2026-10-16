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
import ContainerPersistence
import ContainerResource
import ContainerXPC
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerAPIClient

/// What `ClientImage` sends the images service: a credential given to a pull, push or check
/// travels with that request, and none travels when none was given.
struct RegistryCredentialRequestTests {
    let credential = RegistryCredential(username: "ana", password: "one-shot-pw")
    let system = ContainerSystemConfig()

    @Test("a pull carries the credential it was given, and only then")
    func pull() throws {
        let request = try ClientImage.pullRequest(
            reference: "registry.example/team/app:1", platform: nil, scheme: .https, containerSystemConfig: system, maxConcurrentDownloads: 3,
            credential: credential)
        #expect(try request.registryCredential() == credential)
        #expect(request.string(key: .imageReference) == "registry.example/team/app:1")

        // Control: a pull without one carries none, so the images service uses its own logins.
        let plain = try ClientImage.pullRequest(
            reference: "registry.example/team/app:1", platform: nil, scheme: .https, containerSystemConfig: system, maxConcurrentDownloads: 3,
            credential: nil)
        #expect(try plain.registryCredential() == nil)
    }

    @Test("a push carries the credential it was given, and only then")
    func push() throws {
        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.example/team/app:1",
                descriptor: Descriptor(mediaType: MediaTypes.index, digest: "sha256:" + String(repeating: "a", count: 64), size: 1)))
        let request = try image.pushRequest(platform: nil, scheme: .https, containerSystemConfig: system, credential: credential)
        #expect(try request.registryCredential() == credential)
        #expect(try image.pushRequest(platform: nil, scheme: .https, containerSystemConfig: system, credential: nil).registryCredential() == nil)
    }

    @Test("a check goes on a route of its own, never the login that keeps")
    func check() throws {
        let request = try ClientImage.checkLoginRequest(server: "registry.example", credential: credential, scheme: "https")
        #expect(request.string(key: XPCMessage.routeKey) == ImagesServiceXPCRoute.registryCheck.rawValue)
        #expect(request.string(key: XPCMessage.routeKey) != ImagesServiceXPCRoute.registryLogin.rawValue)
        #expect(try request.registryCredential() == credential)
        // It carries the credential as one value, not the login route's separate fields.
        #expect(request.string(key: .registryPassword) == nil)
    }

    @Test("a credential that does not decode is refused, not read as none")
    func undecodable() {
        let request = XPCMessage(route: .imagePull)
        request.set(key: .registryCredential, value: Data("{\"username\":".utf8))
        #expect(throws: (any Error).self) { try request.registryCredential() }
        // Control: no credential at all is none.
        #expect((try? XPCMessage(route: .imagePull).registryCredential()) == .some(nil))
    }
}
