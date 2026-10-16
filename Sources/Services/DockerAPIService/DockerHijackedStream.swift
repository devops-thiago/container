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
public struct DockerHijackedStream: Sendable {
    public let inbound: NIOAsyncChannelInboundStream<ByteBuffer>
    public let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    public let multiplexed: Bool
    /// The connection underneath, when there is one, for what the async channel does not
    /// expose: whether the client is still there and whether its output has left.
    let channel: (any Channel)?

    public init(
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>, outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>, multiplexed: Bool,
        channel: (any Channel)? = nil
    ) {
        self.inbound = inbound
        self.outbound = outbound
        self.multiplexed = multiplexed
        self.channel = channel
    }

    public func write(_ buffer: ByteBuffer, stream: StdStream = .stdout) async throws {
        try await outbound.write(multiplexed ? StdMultiplexer.frame(buffer, stream: stream) : buffer)
    }

    /// Half-closes the connection: the client sees the end of output, and may still send.
    public func finishWriting() {
        outbound.finish()
    }

    /// Whether the client still holds its end of the connection.
    ///
    /// A client that only closed its sending side (stdin ended) and one that hung up look the
    /// same to a reader on a unix socket: both are EOF. They differ in whether the socket still
    /// has a peer, which `LOCAL_PEERPID` answers: it fails with `ENOTCONN` once the client has
    /// closed the connection, and succeeds after a half-close.
    public func peerConnected() async -> Bool {
        guard let channel else { return true }
        guard channel.isActive else { return false }
        guard let provider = channel as? any SocketOptionProvider else { return true }
        do {
            let _: pid_t = try await provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERPID)).get()
            return true
        } catch {
            return false
        }
    }

    /// Waits until what was written has left for the client, or the client has gone.
    ///
    /// The async writer hands writes to the channel without waiting for the socket, and a
    /// connection whose input already ended closes outright when its output is finished,
    /// dropping whatever the socket had not yet taken. So the last output of a process is
    /// waited out before the half-close, for as long as a client is there to read it.
    public func drain() async {
        guard let channel else { return }
        var looks = 0
        while !Task.isCancelled, channel.isActive {
            guard let buffered = try? await channel.getOption(.bufferedWritableBytes).get(), buffered > 0 else { return }
            looks += 1
            if looks.isMultiple(of: 20), await !peerConnected() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension Channel {
    /// Waits until the channel has written everything handed to it: it has closed, the task is
    /// cancelled, or `timeout` (when there is one) has passed.
    ///
    /// Closing a channel drops the writes it still holds, which `NIOAsyncChannel` does as soon
    /// as its body returns; this is what to wait out first.
    func waitUntilWritten(within timeout: Duration? = nil) async {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        while !Task.isCancelled, isActive, deadline.map({ ContinuousClock.now < $0 }) ?? true {
            guard let buffered = try? await getOption(.bufferedWritableBytes).get(), buffered > 0 else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
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
