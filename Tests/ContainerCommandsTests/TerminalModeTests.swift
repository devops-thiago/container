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

import Testing

@testable import ContainerCommands

struct TerminalModeTests {
    @Test(arguments: [
        ["exec", "-it", "web", "sh"],
        ["exec", "-ti", "web", "sh"],
        ["container", "exec", "-i", "-t", "web", "sh"],
        ["exec", "--interactive", "--tty", "web", "sh"],
        ["run", "-it", "alpine", "sh"],
        ["container", "run", "--tty", "--interactive", "alpine"],
        ["run", "--name=-it", "-it", "alpine"],
    ])
    func interactive(arguments: [String]) {
        #expect(Application.terminalMode(arguments: arguments) == "raw")
    }

    @Test(arguments: [
        ["exec", "web", "sh", "-it"],
        ["exec", "-i", "web", "sh"],
        ["exec", "-t", "web", "sh"],
        ["exec", "-dit", "web", "sh"],
        ["run", "-dit", "alpine"],
        ["run", "--name=-it", "alpine"],
        ["run", "alpine", "sh", "-it"],
        ["run", "--help"], ["exec", "--help"], ["--help"],
        ["run", "-it"], ["exec", "-it"],
        ["ls"], ["registry", "login", "localhost"], ["unknown", "-it"],
    ])
    func preservesOtherCommands(arguments: [String]) {
        #expect(Application.terminalMode(arguments: arguments) == "none")
    }
}
