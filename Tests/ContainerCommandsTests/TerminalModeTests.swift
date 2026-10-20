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
import ContainerResource
import Foundation
import Synchronization
import Testing

@testable import ContainerCommands

struct TerminalModeTests {
    /// A start probe that must not ask for a container: any lookup fails the test.
    private static func noLookup(_ id: String) async -> ContainerSnapshot? {
        Issue.record("the probe looked up \(id)")
        return nil
    }

    @Test(arguments: [
        ["exec", "-it", "web", "sh"],
        ["exec", "-ti", "web", "sh"],
        ["container", "exec", "-i", "-t", "web", "sh"],
        ["exec", "--interactive", "--tty", "web", "sh"],
        ["run", "-it", "alpine", "sh"],
        ["container", "run", "--tty", "--interactive", "alpine"],
        ["run", "--name=-it", "-it", "alpine"],
        // The login shell `machine run` gives without a command is interactive.
        ["machine", "run"],
        ["machine", "run", "-n", "dev"],
        ["machine", "run", "--root"],
        ["machine", "run", "-it", "bash"],
        ["machine", "run", "-n", "dev", "-ti", "bash", "-l"],
    ])
    func interactive(arguments: [String]) async {
        #expect(await Application.terminalMode(arguments: arguments, container: Self.noLookup) == "raw")
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
        // A command, a detached shell or help in a machine has no raw terminal.
        ["machine", "run", "-d"],
        ["machine", "run", "uname", "-a"],
        ["machine", "run", "bash", "-it"],
        ["machine", "run", "-i", "bash"],
        ["machine", "run", "-t", "bash"],
        ["machine", "run", "--help"],
        ["machine", "start"],
        // A start that does not attach stdin never asks for its container.
        ["start", "web"], ["start", "-a", "web"], ["start", "--help"],
        ["system", "start"], ["builder", "start"],
    ])
    func preservesOtherCommands(arguments: [String]) async {
        #expect(await Application.terminalMode(arguments: arguments, container: Self.noLookup) == "none")
    }

    @Test("start -i is raw only for a stopped container whose process has a terminal")
    func start() async {
        let looked = Mutex<[String]>([])
        func mode(_ arguments: [String], terminal: Bool, status: RuntimeStatus = .stopped, exists: Bool = true) async -> String {
            await Application.terminalMode(arguments: arguments) { id in
                looked.withLock { $0.append(id) }
                return exists ? Self.snapshot(id: id, terminal: terminal, status: status) : nil
            }
        }
        #expect(await mode(["start", "-ai", "web"], terminal: true) == "raw")
        #expect(await mode(["start", "-i", "web"], terminal: true) == "raw")
        #expect(await mode(["start", "--attach", "--interactive", "web"], terminal: true) == "raw")
        #expect(looked.withLock { $0 } == ["web", "web", "web"])
        // Controls: without a terminal stdin is a pipe; a running container cannot be
        // attached. Missing metadata must remain distinct from these known states.
        #expect(await mode(["start", "-ai", "web"], terminal: false) == "none")
        #expect(await mode(["start", "-ai", "web"], terminal: true, status: .running) == "none")
        #expect(await mode(["start", "-ai", "web"], terminal: true, exists: false) == "unavailable")
    }

    @Test("a failed start probe is distinct from a known non-TTY session")
    func startAfterFailedLookup() async {
        // Unknown metadata must not authorize a canonical interactive session. The wrapper
        // refuses unavailable probes before executing start; a later attempt can succeed.
        #expect(await Application.terminalMode(arguments: ["start", "-ai", "web"]) { _ in nil } == "unavailable")
        #expect(
            await Application.terminalMode(arguments: ["start", "-ai", "web"]) { id in
                Self.snapshot(id: id, terminal: true, status: .stopped)
            } == "raw", "a later attempt can use the recovered metadata")
        // Control: exec, whose probe only parses, still names the update.
        #expect(await Application.terminalMode(arguments: ["exec", "-it", "web", "sh"], container: Self.noLookup) == "raw")
        #expect(ProcessIO.lineModeNotice(rawConsole: false, launcherSetsRaw: true) != nil)
    }

    private static func snapshot(id: String, terminal: Bool, status: RuntimeStatus) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0))
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: terminal, user: .id(uid: 0, gid: 0),
            supplementalGroups: [], rlimits: [])
        return ContainerSnapshot(configuration: ContainerConfiguration(id: id, image: image, process: process), status: status, networks: [])
    }
}
