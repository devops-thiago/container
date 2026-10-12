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

import ContainerizationError
import ContainerizationOS
import Security
import Testing

@testable import ContainerImagesService

/// Where a registry login goes. The network and the keychain are left to the live smoke; this
/// is the part that decides what is contacted, and over what.
struct RegistryLoginTargetTests {
    @Test("a host and port go over the scheme given, unchanged")
    func schemeIsKept() throws {
        let plain = try ImagesService.loginTarget(server: "localhost:5000", scheme: "http")
        #expect(plain.host == "localhost")
        #expect(plain.port == 5000)
        #expect(plain.scheme == "http")

        let tls = try ImagesService.loginTarget(server: "ghcr.io", scheme: "https")
        #expect(tls.host == "ghcr.io")
        #expect(tls.port == nil)
        #expect(tls.scheme == "https")
    }

    @Test("docker.io is the registry's own host, as the command line resolves it")
    func dockerHubResolves() throws {
        #expect(try ImagesService.loginTarget(server: "docker.io", scheme: "https").host == "registry-1.docker.io")
    }

    @Test("a login another program made says so when it cannot be removed here")
    func otherOwnersLoginIsNamed() throws {
        let mapped = ImagesService.logoutError(KeychainQuery.Error.unhandledError(status: errSecInvalidOwnerEdit), host: "ghcr.io")
        let error = try #require(mapped as? ContainerizationError)
        #expect(error.isCode(.invalidState))
        #expect(error.message.contains("ghcr.io"))
        #expect(error.message.contains("another program"))
    }

    @Test("any other keychain failure passes through unchanged")
    func otherFailuresPassThrough() {
        let mapped = ImagesService.logoutError(KeychainQuery.Error.unhandledError(status: errSecAuthFailed), host: "ghcr.io")
        #expect(!(mapped is ContainerizationError))
    }

    @Test("a scheme other than http or https is refused before anything is contacted")
    func otherSchemesRefused() {
        for scheme in ["", "ftp", "HTTP", "auto"] {
            #expect(throws: ContainerizationError.self) {
                try ImagesService.loginTarget(server: "localhost:5000", scheme: scheme)
            }
        }
    }
}
