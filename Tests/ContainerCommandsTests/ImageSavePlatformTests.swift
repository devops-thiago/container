//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerizationOCI
import Testing

@testable import ContainerCommands

struct ImageSavePlatformTests {
    @Test("ordinary save selects the host platform instead of every index manifest")
    func hostDefault() throws {
        let command = try Application.ImageSave.parse(["fixture:latest"])
        #expect(try command.savePlatform(environment: [:]) == Parser.platform(os: "linux", arch: Arch.hostArchitecture().rawValue))
        #expect(Application.ImageSave.helpMessage().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains("default: Linux on the host architecture"))
    }

    @Test("explicit and environment platforms preserve their precedence")
    func precedence() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        let defaultCommand = try Application.ImageSave.parse(["fixture:latest"])
        #expect(try defaultCommand.savePlatform(environment: env) == Platform(from: "linux/amd64"))
        let explicit = try Application.ImageSave.parse(["--platform", "linux/arm64/v8", "--arch", "amd64", "fixture:latest"])
        #expect(try explicit.savePlatform(environment: env) == Platform(from: "linux/arm64/v8"))
        let architecture = try Application.ImageSave.parse(["--arch", "arm64", "fixture:latest"])
        #expect(try architecture.savePlatform(environment: env) == Platform(from: "linux/arm64"))
        let os = try Application.ImageSave.parse(["--os", "linux", "fixture:latest"])
        #expect(try os.savePlatform(environment: env) == Parser.platform(os: "linux", arch: Arch.hostArchitecture().rawValue))
        #expect(throws: (any Error).self) { try defaultCommand.savePlatform(environment: ["CONTAINER_DEFAULT_PLATFORM": "invalid"]) }
    }
}
