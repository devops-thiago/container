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

/// One Docker Engine API request, read whole: head, body and end.
public struct DockerRequest: Sendable {
    public let method: HTTPMethod
    /// The path without its version prefix, each segment percent-decoded.
    public let segments: [String]
    /// The version the client asked for in the path, or the current one.
    public let apiVersion: DockerAPIVersion
    public let query: [String: [String]]
    public let headers: HTTPHeaders
    public let body: ByteBuffer
    /// The body, when the HTTP layer spooled it to a file instead (`DockerBodySpool`); `body` is
    /// then empty. The file is deleted once the answer has been sent.
    public let bodyFile: URL?

    public var path: String { "/" + segments.joined(separator: "/") }

    public init(
        method: HTTPMethod, segments: [String], apiVersion: DockerAPIVersion = .current,
        query: [String: [String]] = [:], headers: HTTPHeaders = [:], body: ByteBuffer = ByteBuffer(), bodyFile: URL? = nil
    ) {
        self.method = method
        self.segments = segments
        self.apiVersion = apiVersion
        self.query = query
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
    }

    /// Splits a request target into its version, path segments and query.
    ///
    /// Segments are split before they are decoded, so an encoded slash stays inside its segment.
    /// The query is decoded as Go's `url.ParseQuery` does, `+` included, because the Docker CLI
    /// encodes with Go. A version outside what this service implements is refused with dockerd's
    /// wording, which the CLI shows as it is.
    public init(method: HTTPMethod, uri: String, headers: HTTPHeaders, body: ByteBuffer, bodyFile: URL? = nil) throws(DockerAPIError) {
        let target = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var raw = target[0].split(separator: "/").map(String.init)
        var version = DockerAPIVersion.current
        if let first = raw.first, first.hasPrefix("v"), let asked = DockerAPIVersion(first.dropFirst()) {
            guard asked >= .minimum else {
                throw .badRequest(
                    "client version \(asked) is too old. Minimum supported API version is \(DockerAPIVersion.minimum), please upgrade your client to a newer version"
                )
            }
            guard asked <= .current else {
                throw .badRequest("client version \(asked) is too new. Maximum supported API version is \(DockerAPIVersion.current)")
            }
            version = asked
            raw.removeFirst()
        }
        let segments = try raw.map { segment throws(DockerAPIError) in
            guard let decoded = segment.removingPercentEncoding else { throw .badRequest("invalid path: \(uri)") }
            return decoded
        }
        self.init(
            method: method, segments: segments, apiVersion: version,
            query: target.count > 1 ? Self.parseQuery(String(target[1])) : [:], headers: headers, body: body, bodyFile: bodyFile)
    }

    /// The path segments of a request target without its version prefix, decoded, for deciding
    /// how to read a request before it is parsed. Nil when it cannot be parsed.
    static func routeSegments(of uri: String) -> [String]? {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var raw = path.split(separator: "/").map(String.init)
        if let first = raw.first, first.hasPrefix("v"), DockerAPIVersion(first.dropFirst()) != nil {
            raw.removeFirst()
        }
        var segments: [String] = []
        for segment in raw {
            guard let decoded = segment.removingPercentEncoding else { return nil }
            segments.append(decoded)
        }
        return segments
    }

    static func parseQuery(_ text: String) -> [String: [String]] {
        var query: [String: [String]] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (part: Substring) in
                part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            let key = decode(parts[0])
            guard !key.isEmpty else { continue }
            query[key, default: []].append(parts.count > 1 ? decode(parts[1]) : "")
        }
        return query
    }

    /// The first value of a query parameter.
    public func query(_ name: String) -> String? {
        query[name]?.first
    }

    /// A boolean query parameter as dockerd reads one: `1` or `true` is true, `0`, `false` and
    /// an empty value are false, and an absent one is `default`.
    public func bool(_ name: String, default value: Bool = false) throws(DockerAPIError) -> Bool {
        guard let text = query(name) else { return value }
        switch text.lowercased() {
        case "1", "true": return true
        case "0", "false", "": return false
        default: throw .badRequest("invalid value for \(name): \(text)")
        }
    }

    /// An integer query parameter, or nil when it is absent.
    public func int(_ name: String) throws(DockerAPIError) -> Int? {
        guard let text = query(name), !text.isEmpty else { return nil }
        guard let value = Int(text) else { throw .badRequest("invalid value for \(name): \(text)") }
        return value
    }

    /// The `filters` parameter: JSON from the client, in either of the shapes the CLI has sent,
    /// `{"label":{"a=b":true}}` or the older `{"label":["a=b"]}`.
    public func filters() throws(DockerAPIError) -> [String: [String]] {
        guard let text = query("filters"), !text.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw .badRequest("invalid filters: \(text)")
        }
        var filters: [String: [String]] = [:]
        for (key, value) in object {
            switch value {
            case let set as [String: Any]:
                filters[key] = set.compactMap { ($0.value as? Bool) == true ? $0.key : nil }.sorted()
            case let list as [String]:
                filters[key] = list
            default:
                throw .badRequest("invalid filter '\(key)'")
            }
        }
        return filters
    }

    /// Decodes a JSON body. An empty body is refused, since every route that reads one needs it.
    public func decode<T: Decodable>(_ type: T.Type) throws(DockerAPIError) -> T {
        guard body.readableBytes > 0 else { throw .badRequest("request body is empty") }
        do {
            return try JSONDecoder().decode(type, from: Data(body.readableBytesView))
        } catch {
            throw .badRequest("invalid JSON body: \(error)")
        }
    }
}
