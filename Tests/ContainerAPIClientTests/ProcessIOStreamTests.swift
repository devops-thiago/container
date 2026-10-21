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

/// `run -a`: only the streams named are attached, as Docker's `--attach`.
struct ProcessIOStreamTests {
    private func attached(_ streams: [Flags.Management.AttachStream], interactive: Bool = false) throws -> [Bool] {
        let io = try ProcessIO.create(tty: false, interactive: interactive, detach: false, streams: streams)
        defer { try? io.close() }
        return io.stdio.map { $0 != nil }
    }

    @Test("without -a every stream is attached; with it, only the ones named")
    func onlyNamedStreams() throws {
        #expect(try attached([]) == [false, true, true])
        #expect(try attached([.stdout, .stderr]) == [false, true, true])
        #expect(try attached([.stdout]) == [false, true, false])
        #expect(try attached([.stderr]) == [false, false, true])
        // -i without -a stdin leaves stdin alone, as dockerd's attach does.
        #expect(try attached([.stdout], interactive: true) == [false, true, false])
    }
}
