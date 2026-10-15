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
import NIOHTTP1

/// What a route answers with.
public enum DockerResponse: Sendable {
    /// A whole response, sent with its length.
    case data(status: HTTPResponseStatus, contentType: String, body: ByteBuffer, headers: HTTPHeaders = [:])
    /// A response whose body is written as it is produced: `wait`, followed logs, stats, events,
    /// pull progress. Its head is sent and flushed before `body` runs, because a client may be
    /// waiting on the head alone: the CLI holds `start` until `wait`'s headers arrive.
    case stream(status: HTTPResponseStatus, contentType: String, body: @Sendable (DockerResponseWriter) async throws -> Void)
    /// `101 UPGRADED`, after which the connection carries a process's stdio for `attach` and
    /// exec `start`. `multiplexed` is Docker's 8-byte-framed stream (no tty); otherwise raw.
    case hijack(multiplexed: Bool, body: @Sendable (DockerHijackedStream) async throws -> Void)

    public static func json(_ value: some Encodable, status: HTTPResponseStatus = .ok) throws(DockerAPIError) -> Self {
        let data: Data
        do {
            data = try DockerJSON.encoder.encode(value)
        } catch {
            throw .internalError("could not encode the response: \(error)")
        }
        return .data(status: status, contentType: "application/json", body: ByteBuffer(bytes: data))
    }

    public static func text(_ value: String, status: HTTPResponseStatus = .ok) -> Self {
        .data(status: status, contentType: "text/plain; charset=utf-8", body: ByteBuffer(string: value))
    }

    public static func empty(_ status: HTTPResponseStatus = .noContent) -> Self {
        .data(status: status, contentType: "text/plain; charset=utf-8", body: ByteBuffer())
    }

    static func error(_ error: DockerAPIError) -> Self {
        .data(status: error.status, contentType: "application/json", body: ByteBuffer(bytes: error.jsonBody))
    }
}

/// The JSON encoding every response uses.
enum DockerJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

/// Writes the body of a streamed response.
///
/// Each write completes once it reaches the socket, so a producer that awaits its writes is
/// held back by a slow client instead of buffering without bound.
public struct DockerResponseWriter: Sendable {
    let channel: any Channel

    public func write(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    }

    public func write(_ text: String) async throws {
        try await write(ByteBuffer(string: text))
    }

    /// One JSON value followed by a newline: the framing of `wait`, stats, events and progress.
    public func writeJSON(_ value: some Encodable) async throws {
        var data = try DockerJSON.encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try await write(ByteBuffer(bytes: data))
    }
}
