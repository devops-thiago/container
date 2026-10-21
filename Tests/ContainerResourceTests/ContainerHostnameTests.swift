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

import Foundation
import Testing

@testable import ContainerResource

struct ContainerHostnameTests {
    @Test func aNameThatFitsIsTheHostname() {
        #expect(ContainerHostname.default(for: "web") == "web")
        #expect(ContainerHostname.default(for: "my_project-app-1") == "my_project-app-1")
        #expect(ContainerHostname.default(for: String(repeating: "a", count: 63)) == String(repeating: "a", count: 63))
        // A dotted name keeps the meaning it had: each label fits.
        #expect(ContainerHostname.default(for: "web.example") == "web.example")
    }

    @Test func aLongerNameGetsItsShortID() {
        let name = "6038_desenvolvimento_backend_com_ia_essencial_java_devcontainer-mysql-1"
        let hostname = ContainerHostname.default(for: name)
        #expect(hostname.count == 12)
        #expect(hostname.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(hostname == String(ContainerHostname.dockerID(for: name).prefix(12)))
        // The same name always gets the same hostname, and names sharing their first 63
        // characters get different ones.
        #expect(ContainerHostname.default(for: name) == hostname)
        #expect(ContainerHostname.default(for: name.replacingOccurrences(of: "mysql", with: "app")) != hostname)
        #expect(ContainerHostname.default(for: String(repeating: "a", count: 64)) != ContainerHostname.default(for: String(repeating: "a", count: 65)))
    }

    @Test func dockerIDIsTheSHA256OfTheID() {
        // printf %s web | shasum -a 256
        #expect(ContainerHostname.dockerID(for: "web") == "4b5e57f6eb2f42b9039b3d1e13929295f231749c510cbe341cd68036d9af97e2")
        #expect(ContainerHostname.shortID(for: "web") == "4b5e57f6eb2f")
    }
}
