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

import Logging
import NIOHTTP1

/// Values a route pattern captured from the path.
public struct RouteParameters: Sendable {
    let values: [String: String]

    /// A captured value. Routes only ask for names their pattern has, so a miss is a
    /// programming error answered as a 500 rather than a crash.
    public subscript(_ name: String) -> String {
        get throws(DockerAPIError) {
            guard let value = values[name] else { throw .internalError("route has no parameter '\(name)'") }
            return value
        }
    }
}

/// Matches requests to routes.
///
/// A pattern is a path of literal segments and parameters: `{id}` captures one segment, and
/// `{name+}` captures one or more, because image references carry slashes
/// (`/images/ghcr.io/org/app:1/json`). A pattern has at most one greedy parameter. Where two
/// patterns match, the one with more literal segments wins, so `/containers/json` is not read as
/// a container named `json`.
public struct DockerRouter: Sendable {
    public typealias Handler = @Sendable (DockerRequest, RouteParameters) async throws -> DockerResponse

    struct Route: Sendable {
        enum Segment: Sendable, Equatable {
            case literal(String)
            case parameter(String)
            case greedy(String)
        }

        let method: HTTPMethod
        let segments: [Segment]
        let handler: Handler

        var literalCount: Int {
            segments.filter { if case .literal = $0 { true } else { false } }.count
        }

        func match(_ path: [String]) -> [String: String]? {
            guard let greedy = segments.firstIndex(where: { if case .greedy = $0 { true } else { false } }) else {
                guard path.count == segments.count else { return nil }
                return Self.match(segments[...], path[...])
            }
            let after = segments.count - greedy - 1
            guard path.count >= greedy + 1 + after else { return nil }
            guard var values = Self.match(segments[..<greedy], path[..<greedy]),
                let tail = Self.match(segments[(greedy + 1)...], path[(path.count - after)...])
            else { return nil }
            guard case .greedy(let name) = segments[greedy] else { return nil }
            values[name] = path[greedy..<(path.count - after)].joined(separator: "/")
            values.merge(tail) { first, _ in first }
            return values
        }

        private static func match(_ pattern: ArraySlice<Segment>, _ path: ArraySlice<String>) -> [String: String]? {
            var values: [String: String] = [:]
            for (segment, part) in zip(pattern, path) {
                switch segment {
                case .literal(let text):
                    guard text == part else { return nil }
                case .parameter(let name):
                    guard !part.isEmpty else { return nil }
                    values[name] = part
                case .greedy:
                    return nil
                }
            }
            return values
        }
    }

    private var routes: [Route] = []
    private let log: Logger
    /// Asked before every route runs; a non-nil answer is sent instead. The agent refuses
    /// everything while no app owns the engine.
    public var gate: (@Sendable () async -> DockerAPIError?)?

    public init(log: Logger = Logger(label: "DockerAPIService")) {
        self.log = log
    }

    public mutating func add(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        let segments = pattern.split(separator: "/").map { part -> Route.Segment in
            if part.hasPrefix("{") && part.hasSuffix("+}") { return .greedy(String(part.dropFirst().dropLast(2))) }
            if part.hasPrefix("{") && part.hasSuffix("}") { return .parameter(String(part.dropFirst().dropLast())) }
            return .literal(String(part))
        }
        precondition(segments.filter { if case .greedy = $0 { true } else { false } }.count <= 1, "one greedy parameter per pattern")
        routes.append(Route(method: method, segments: segments, handler: handler))
        // Most literal segments first; ties keep the order they were added in.
        routes = routes.enumerated().sorted { ($0.element.literalCount, -$0.offset) > ($1.element.literalCount, -$1.offset) }.map(\.element)
    }

    /// Runs the route for `request`. Never throws: an error becomes the client's error body.
    ///
    /// Only the method and path are logged. Headers and bodies are not, because they carry
    /// registry credentials (`X-Registry-Auth`, `/auth`).
    public func respond(to request: DockerRequest) async -> DockerResponse {
        // HEAD is answered by the GET route, without its body.
        let method = request.method == .HEAD ? HTTPMethod.GET : request.method
        for route in routes where route.method == method {
            guard let values = route.match(request.segments) else { continue }
            if let gate, let refusal = await gate() {
                return .error(refusal)
            }
            do {
                return try await route.handler(request, RouteParameters(values: values))
            } catch let error as DockerAPIError {
                log.debug("request failed", metadata: ["method": "\(request.method)", "path": "\(request.path)", "status": "\(error.status.code)"])
                return .error(error)
            } catch {
                log.error("request failed", metadata: ["method": "\(request.method)", "path": "\(request.path)", "error": "\(error)"])
                return .error(.internalError("\(error)"))
            }
        }
        log.debug("no route", metadata: ["method": "\(request.method)", "path": "\(request.path)"])
        return .error(.pageNotFound)
    }
}
