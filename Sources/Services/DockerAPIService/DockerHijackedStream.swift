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

/// Which of a process's streams a frame carries.
public enum StdStream: UInt8, Sendable {
    case stdin = 0
    case stdout = 1
    case stderr = 2
}

/// A connection after `101 UPGRADED`: the bytes the client sends are the process's stdin, and
/// what is written goes back as its output.
///
/// Without a tty the output is multiplexed, so `write(_:stream:)` frames it; with one it goes
/// raw. Finishing writes is the half-close the CLI waits for before it reads the exit code.
public struct DockerHijackedStream {
    public let inbound: NIOAsyncChannelInboundStream<ByteBuffer>
    public let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    public let multiplexed: Bool

    public func write(_ buffer: ByteBuffer, stream: StdStream = .stdout) async throws {
        try await outbound.write(multiplexed ? StdMultiplexer.frame(buffer, stream: stream) : buffer)
    }

    /// Half-closes the connection: the client sees the end of output, and may still send.
    public func finishWriting() {
        outbound.finish()
    }
}

/// Docker's multiplexed stream framing: an 8-byte header, `[stream, 0, 0, 0, size (UInt32,
/// big-endian)]`, then the payload.
public enum StdMultiplexer {
    public static let headerSize = 8

    public static func frame(_ payload: ByteBuffer, stream: StdStream) -> ByteBuffer {
        var payload = payload
        var framed = ByteBuffer()
        framed.reserveCapacity(payload.readableBytes + headerSize)
        // A frame's size field is 32 bits; larger payloads go as several frames.
        while payload.readableBytes > 0 {
            let size = min(payload.readableBytes, Int(UInt32.max))
            framed.writeInteger(stream.rawValue)
            framed.writeBytes([0, 0, 0])
            framed.writeInteger(UInt32(size), endianness: .big)
            var chunk = payload.readSlice(length: size)!
            framed.writeBuffer(&chunk)
        }
        return framed
    }

    /// Reassembles frames from bytes that may arrive split anywhere.
    public struct Decoder {
        private var pending = ByteBuffer()

        public init() {}

        /// The complete frames `bytes` finished. Bytes of an incomplete frame are kept for the
        /// next call.
        public mutating func feed(_ bytes: ByteBuffer) throws(DockerAPIError) -> [(StdStream, ByteBuffer)] {
            var bytes = bytes
            pending.writeBuffer(&bytes)
            var frames: [(StdStream, ByteBuffer)] = []
            while pending.readableBytes >= StdMultiplexer.headerSize {
                let start = pending.readerIndex
                guard let kind = pending.getInteger(at: start, as: UInt8.self).flatMap(StdStream.init(rawValue:)) else {
                    throw .badRequest("invalid stream type in a multiplexed frame")
                }
                let size = Int(pending.getInteger(at: start + 4, endianness: .big, as: UInt32.self)!)
                guard pending.readableBytes >= StdMultiplexer.headerSize + size else { break }
                pending.moveReaderIndex(forwardBy: StdMultiplexer.headerSize)
                frames.append((kind, pending.readSlice(length: size)!))
            }
            pending.discardReadBytes()
            return frames
        }
    }
}
