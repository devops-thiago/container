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

import ContainerAPIClient
import Testing

@testable import ContainerCommands

struct ImagePullTests {
    @Test("the public convenience initializer defaults to a supported secure transport")
    func defaultTransportIsHTTPS() throws {
        let command = Application.ImagePull(reference: "example.invalid/repository:tag")

        #expect(command.registry.scheme == "https")
        #expect(try RequestScheme(command.registry.scheme) == .https)
    }

    @Test("the public convenience initializer preserves an explicit HTTP transport")
    func explicitHTTPTransport() throws {
        let command = Application.ImagePull(scheme: "http", reference: "localhost:5000/repository:tag")

        #expect(command.registry.scheme == "http")
        #expect(try RequestScheme(command.registry.scheme) == .http)
    }
}
