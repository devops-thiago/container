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

import NIOCore
import Testing

@testable import DockerAPIService

struct StdMultiplexerTests {
    @Test("a frame is the stream byte, three zeros, the big-endian size, then the payload")
    func frameLayout() {
        let framed = StdMultiplexer.frame(ByteBuffer(string: "hi\n"), stream: .stderr)
        #expect(Array(framed.readableBytesView) == [2, 0, 0, 0, 0, 0, 0, 3, 104, 105, 10])
    }

    @Test("frames split anywhere are put back together")
    func decodeAcrossSplits() throws {
        var bytes = StdMultiplexer.frame(ByteBuffer(string: "out"), stream: .stdout)
        var second = StdMultiplexer.frame(ByteBuffer(string: "err!"), stream: .stderr)
        bytes.writeBuffer(&second)
        let all = Array(bytes.readableBytesView)
        for split in 0...all.count {
            var decoder = StdMultiplexer.Decoder()
            let frames = try decoder.feed(ByteBuffer(bytes: all[..<split])) + decoder.feed(ByteBuffer(bytes: all[split...]))
            #expect(frames.map(\.0) == [.stdout, .stderr], "split at \(split)")
            #expect(frames.map { String(buffer: $0.1) } == ["out", "err!"], "split at \(split)")
        }
    }

    @Test("an empty payload makes no frame, and an unknown stream byte is refused")
    func edges() throws {
        #expect(StdMultiplexer.frame(ByteBuffer(), stream: .stdout).readableBytes == 0)
        var decoder = StdMultiplexer.Decoder()
        #expect(throws: DockerAPIError.self) { try decoder.feed(ByteBuffer(bytes: [9, 0, 0, 0, 0, 0, 0, 0])) }
    }
}
