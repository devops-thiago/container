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

@testable import DockerAPIService

/// The engine's request closes each descriptor it sends (`XPCMessage.set`). A pipe that handed
/// over its own descriptor and then closed it too closed the number twice; by the second close
/// another exec could hold that number, and the agent trapped on the descriptor it lost.
struct StdioPipeTests {
    @Test("a failed later duplication closes earlier copies without closing the pipes", arguments: [2, 3])
    func failedDuplicationRollsBack(failingCall: Int) throws {
        let input = try StdioPipe(.intoContainer)
        let output = try StdioPipe(.outOfContainer)
        let error = try StdioPipe(.outOfContainer)
        var calls = 0
        var descriptors: [Int32] = []
        var copies: [FileHandle] = []
        defer {
            // Clean up a failing negative control as well.
            for handle in copies { try? handle.close() }
        }
        #expect(throws: POSIXError(.EMFILE)) {
            try DockerProcessStdio.duplicating(stdin: input, stdout: output, stderr: error) { pipe in
                calls += 1
                if calls == failingCall { throw POSIXError(.EMFILE) }
                let handle = try #require(try pipe.containerHandleForEngine())
                descriptors.append(handle.fileDescriptor)
                copies.append(handle)
                return handle
            }
        }
        #expect(descriptors.count == failingCall - 1)
        for fd in descriptors {
            #expect(fcntl(fd, F_GETFD) == -1, "the earlier duplicate must be closed on failure")
            #expect(errno == EBADF)
        }
        for pipe in [input, output, error] {
            #expect(fcntl(try #require(pipe.container), F_GETFD) != -1)
            #expect(fcntl(try #require(pipe.host), F_GETFD) != -1)
        }
    }

    @Test("successful duplication keeps stream positions and transfers each copy once")
    func duplicateStreams() throws {
        let output = try StdioPipe(.outOfContainer)
        let stdio = try DockerProcessStdio.duplicating(stdout: output)
        #expect(stdio.stdin == nil)
        #expect(stdio.stderr == nil)
        let handle = try #require(stdio.stdout)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(handle.fileDescriptor != output.container)
        try handle.close()
        #expect(fcntl(try #require(output.container), F_GETFD) != -1)
    }

    @Test("the engine gets a copy of the container's end, never the descriptor the pipe closes")
    func engineGetsACopy() throws {
        for direction in [StdioPipe.Direction.intoContainer, .outOfContainer] {
            let pipe = try StdioPipe(direction)
            let own = try #require(pipe.container)
            let handed = try #require(try pipe.containerHandleForEngine())
            #expect(handed.fileDescriptor != own)
            #expect(handed.fileDescriptor != pipe.host)
            #expect(fcntl(handed.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
            // What the engine's request does with it.
            close(handed.fileDescriptor)
            // The pipe's own end is still open until the pipe closes it.
            #expect(fcntl(own, F_GETFD) != -1)
            pipe.closeContainerEnd()
            #expect(pipe.container == nil)
        }
    }

    @Test("once the engine closed its copy and the pipe its end, the agent's end of an output pipe reads EOF")
    func outputEndsWhenBothCopiesClose() throws {
        let pipe = try StdioPipe(.outOfContainer)
        let handed = try #require(try pipe.containerHandleForEngine())
        close(handed.fileDescriptor)
        pipe.closeContainerEnd()
        let host = try #require(pipe.takeHost())
        defer { close(host) }
        _ = fcntl(host, F_SETFL, fcntl(host, F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        // 0 is EOF; -1 with EAGAIN would mean a write end was left open.
        #expect(read(host, &byte, 1) == 0)
    }

    @Test("a pipe with no container end left hands the engine nothing")
    func nothingToHand() throws {
        let pipe = try StdioPipe(.intoContainer)
        pipe.closeContainerEnd()
        #expect(try pipe.containerHandleForEngine() == nil)
    }
}
