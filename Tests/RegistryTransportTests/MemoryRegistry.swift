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

import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// A plain-HTTP registry on loopback that keeps what is pushed to it in memory, as the
/// distribution registry does with an htpasswd file: every request needs the one Basic login,
/// and is recorded with the `Authorization` it carried.
final class MemoryRegistry: Sendable {
    /// Where the registry says an upload goes.
    enum LocationStyle: Sendable {
        /// A path and a `_state` query, as `registry:2` sends with relative URLs on.
        case relative
        /// The same, on this registry's own origin.
        case absolute
        /// The same path on another origin.
        case otherOrigin
    }

    struct Request: Sendable, Equatable {
        var method: HTTPMethod
        var uri: String
        var authorization: String?
    }

    private struct Manifest: Sendable {
        var mediaType: String
        var bytes: [UInt8]
        var digest: String
    }

    private struct State: Sendable {
        var blobs: [String: [UInt8]] = [:]
        var manifests: [String: Manifest] = [:]
        var uploads: [String: String] = [:]
        var requests: [Request] = []
    }

    let host = "127.0.0.1"
    let port: Int
    private let channel: any Channel
    private let state: Mutex<State>

    var requests: [Request] { state.withLock { $0.requests } }

    /// The digest the registry keeps under `name:reference`, if any.
    func manifestDigest(_ name: String, _ reference: String) -> String? {
        state.withLock { $0.manifests["\(name):\(reference)"]?.digest }
    }

    func hasBlob(_ digest: String) -> Bool {
        state.withLock { $0.blobs[digest] != nil }
    }

    private init(channel: any Channel) {
        self.channel = channel
        self.state = Mutex(State())
        self.port = channel.localAddress?.port ?? 0
    }

    static func start(username: String, password: String, location: LocationStyle = .relative) async throws -> MemoryRegistry {
        let expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let box = Box()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(box: box, expected: expected, location: location))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let registry = MemoryRegistry(channel: channel)
        box.registry.withLock { $0 = registry }
        return registry
    }

    func stop() async {
        try? await channel.close().get()
    }

    /// Runs `body` against a registry that takes `username` and `password`, and stops it after.
    @discardableResult
    static func serving<T>(
        username: String, password: String, location: LocationStyle = .relative, _ body: (MemoryRegistry) async throws -> T
    ) async throws -> T {
        let registry = try await start(username: username, password: password, location: location)
        do {
            let result = try await body(registry)
            await registry.stop()
            return result
        } catch {
            await registry.stop()
            throw error
        }
    }

    private final class Box: Sendable {
        let registry = Mutex<MemoryRegistry?>(nil)
    }

    private struct Reply {
        var status: HTTPResponseStatus
        var headers: [(String, String)] = []
        var body: [UInt8] = []
    }

    static func digest(_ bytes: [UInt8]) -> String {
        "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// What the registry answers `method` on `uri`, carrying `body`.
    private func answer(_ method: HTTPMethod, _ uri: String, body: [UInt8], location: LocationStyle) -> Reply {
        let url = URLComponents(string: uri)
        let path = url?.path ?? uri
        let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if path == "/v2/" { return Reply(status: .ok) }
        if method == .POST, path.hasSuffix("/blobs/uploads/") {
            let name = String(path.dropFirst("/v2/".count).dropLast("/blobs/uploads/".count))
            let id = UUID().uuidString.lowercased()
            let session = "s-\(id)"
            state.withLock { $0.uploads[id] = session }
            let relative = "/v2/\(name)/blobs/uploads/\(id)?_state=\(session)"
            let target: String
            switch location {
            case .relative: target = relative
            case .absolute: target = "http://\(host):\(port)\(relative)"
            case .otherOrigin: target = "http://198.51.100.7:\(port)\(relative)"
            }
            return Reply(status: .accepted, headers: [("Location", target), ("Docker-Upload-UUID", id), ("Range", "0-0")])
        }
        if method == .PUT, let range = path.range(of: "/blobs/uploads/") {
            let id = String(path[range.upperBound...])
            guard let session = state.withLock({ $0.uploads[id] }), query["_state"] == session, let digest = query["digest"] else {
                return Reply(status: .badRequest)
            }
            guard Self.digest(body) == digest else { return Reply(status: .badRequest) }
            state.withLock {
                $0.blobs[digest] = body
                $0.uploads[id] = nil
            }
            return Reply(status: .created, headers: [("Docker-Content-Digest", digest)])
        }
        if let range = path.range(of: "/blobs/", options: .backwards) {
            let digest = String(path[range.upperBound...])
            guard let blob = state.withLock({ $0.blobs[digest] }) else { return Reply(status: .notFound) }
            return Reply(status: .ok, headers: [("Docker-Content-Digest", digest), ("Content-Type", "application/octet-stream")], body: blob)
        }
        if let range = path.range(of: "/manifests/", options: .backwards) {
            let name = String(path[path.index(path.startIndex, offsetBy: "/v2/".count)..<range.lowerBound])
            let reference = String(path[range.upperBound...])
            if method == .PUT {
                let manifest = Manifest(mediaType: "", bytes: body, digest: Self.digest(body))
                state.withLock {
                    $0.manifests["\(name):\(reference)"] = manifest
                    $0.manifests["\(name):\(manifest.digest)"] = manifest
                }
                return Reply(status: .created, headers: [("Docker-Content-Digest", manifest.digest)])
            }
            guard let manifest = state.withLock({ $0.manifests["\(name):\(reference)"] }) else { return Reply(status: .notFound) }
            let mediaType = (try? JSONSerialization.jsonObject(with: Data(manifest.bytes)) as? [String: Any])?["mediaType"] as? String
            return Reply(
                status: .ok, headers: [("Docker-Content-Digest", manifest.digest), ("Content-Type", mediaType ?? "application/vnd.oci.image.index.v1+json")],
                body: manifest.bytes)
        }
        return Reply(status: .notFound)
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let box: Box
        let expected: String
        let location: LocationStyle
        private var head: HTTPRequestHead?
        private var body: [UInt8] = []

        init(box: Box, expected: String, location: LocationStyle) {
            self.box = box
            self.expected = expected
            self.location = location
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body = []
            case .body(var buffer):
                body += buffer.readBytes(length: buffer.readableBytes) ?? []
            case .end:
                guard let head, let registry = box.registry.withLock({ $0 }) else { return }
                let authorization = head.headers.first(name: "Authorization")
                registry.state.withLock { $0.requests.append(Request(method: head.method, uri: head.uri, authorization: authorization)) }
                let reply: Reply
                if authorization == expected {
                    reply = registry.answer(head.method, head.uri, body: body, location: location)
                } else {
                    reply = Reply(status: .unauthorized, headers: [("WWW-Authenticate", #"Basic realm="memory""#)])
                }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "\(reply.body.count)")
                for (name, value) in reply.headers { headers.add(name: name, value: value) }
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: reply.status, headers: headers))), promise: nil)
                if head.method != .HEAD, !reply.body.isEmpty {
                    context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: reply.body)))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                self.head = nil
            }
        }
    }
}
