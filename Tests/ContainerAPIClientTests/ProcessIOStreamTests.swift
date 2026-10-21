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

@testable import ContainerAPIClient

/// `run -a`: the streams attached, as the Docker CLI attaches them.
struct ProcessIOStreamTests {
    private func attached(
        _ streams: [Flags.Management.AttachStream], interactive: Bool = false, tty: Bool = false, detach: Bool = false
    ) -> [Bool] {
        let chosen = ProcessIO.attachedStreams(tty: tty, interactive: interactive, detach: detach, streams: streams)
        return [chosen.stdin, chosen.stdout, chosen.stderr]
    }

    @Test("without -a both outputs are attached; with it, only the ones named")
    func onlyNamedStreams() {
        #expect(attached([]) == [false, true, true])
        #expect(attached([.stdout, .stderr]) == [false, true, true])
        #expect(attached([.stdout]) == [false, true, false])
        #expect(attached([.stderr]) == [false, false, true])
        #expect(attached([.stdout], tty: true) == [false, true, false])
        #expect(attached([], detach: true) == [false, false, false])
    }

    @Test("-i attaches stdin whatever -a names, and -a stdin alone does not open it")
    func stdinFollowsInteractive() {
        // The Docker CLI sets attachStdin for -i (cli/command/container/opts.go).
        #expect(attached([.stdout], interactive: true) == [true, true, false])
        #expect(attached([], interactive: true) == [true, true, true])
        #expect(attached([.stdin]) == [false, false, false])
    }

    @Test("the pipes made are the streams chosen")
    func pipesFollowTheChoice() throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: false, streams: [.stdout])
        defer { try? io.close() }
        #expect(io.stdio.map { $0 != nil } == [false, true, false])
    }
}
