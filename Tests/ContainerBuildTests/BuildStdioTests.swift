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

import ContainerizationOS
import Foundation
import Testing

@testable import ContainerBuild

struct BuildStdioTests {
    static func ioPacket(_ text: String) -> ServerStream {
        var io = IO()
        io.type = .stdout
        io.data = Data(text.utf8)
        var packet = ServerStream()
        packet.buildID = "build"
        packet.packetType = .io(io)
        return packet
    }

    @Test func relaysOutputToTheHandle() async throws {
        let pipe = Pipe()
        let stdio = try BuildStdio(output: pipe.fileHandleForWriting)
        let (_, sender) = AsyncStream.makeStream(of: ClientStream.self)

        try await stdio.handle(sender, Self.ioPacket("step 1\n"))
        try await stdio.handle(sender, Self.ioPacket("step 2\n"))
        try pipe.fileHandleForWriting.close()

        let written = try pipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(String(decoding: written, as: UTF8.self) == "step 1\nstep 2\n")
        #expect(await stdio.outputGone == false)
    }

    /// An app closes its pty once a build throws, while a pipeline task may still be relaying
    /// output. `FileHandle.write(_:)` would raise an Objective-C exception here and take the
    /// process down; the relay must drop the output instead.
    @Test func closedHandleDropsOutputWithoutFailing() async throws {
        let pipe = Pipe()
        let output = pipe.fileHandleForWriting
        let stdio = try BuildStdio(output: output)
        let (_, sender) = AsyncStream.makeStream(of: ClientStream.self)
        try output.close()

        try await stdio.handle(sender, Self.ioPacket("lost\n"))
        #expect(await stdio.outputGone)
        try await stdio.handle(sender, Self.ioPacket("also lost\n"))
        #expect(await stdio.outputGone)
    }

    /// The pty an app hands the build, with the app's side closed under it.
    @Test func ptyWithItsParentClosedDropsOutputWithoutFailing() async throws {
        let (parent, child) = try Terminal.create()
        defer { try? child.close() }
        let stdio = try BuildStdio(output: child.handle)
        let (_, sender) = AsyncStream.makeStream(of: ClientStream.self)
        try parent.close()

        for line in 0..<64 {
            try await stdio.handle(sender, Self.ioPacket("line \(line)\n"))
        }
    }

    /// Quiet builds never touch the handle, closed or not.
    @Test func quietIgnoresOutput() async throws {
        let pipe = Pipe()
        let stdio = try BuildStdio(quiet: true, output: pipe.fileHandleForWriting)
        let (_, sender) = AsyncStream.makeStream(of: ClientStream.self)
        try pipe.fileHandleForWriting.close()

        try await stdio.handle(sender, Self.ioPacket("quiet\n"))
        #expect(await stdio.outputGone == false)
    }
}
