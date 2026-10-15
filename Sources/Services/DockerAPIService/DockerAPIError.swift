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
import NIOHTTP1

/// An error answered to a Docker client as `{"message": …}` with an HTTP status, the shape the
/// Docker CLI prints after "Error response from daemon:".
public struct DockerAPIError: Error, Sendable, Equatable {
    public let status: HTTPResponseStatus
    public let message: String

    public init(_ status: HTTPResponseStatus, _ message: String) {
        self.status = status
        self.message = message
    }

    public static func notFound(_ message: String) -> Self { .init(.notFound, message) }
    public static func badRequest(_ message: String) -> Self { .init(.badRequest, message) }
    public static func conflict(_ message: String) -> Self { .init(.conflict, message) }
    public static func notImplemented(_ message: String) -> Self { .init(.notImplemented, message) }
    public static func internalError(_ message: String) -> Self { .init(.internalServerError, message) }

    /// What dockerd answers for a path it has no route for.
    public static let pageNotFound = Self(.notFound, "page not found")

    struct Body: Encodable {
        let message: String
    }

    var jsonBody: Data {
        // Encoding a single string field cannot fail.
        (try? JSONEncoder().encode(Body(message: message))) ?? Data(#"{"message":"internal error"}"#.utf8)
    }
}
