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

import ContainerAPIClient
import ContainerResource
import DockerAPIService

/// The engine's container events, through the client the `container` commands use. An engine
/// that does not say it has them is not asked: it would not answer the route.
public struct EngineEventFeedClient: DockerEngineEventFeed {
    public init() {}

    public func available() async -> Bool? {
        guard let health = try? await ClientHealthCheck.ping(timeout: .seconds(5)) else { return nil }
        return health.supports(.containerEvents)
    }

    public func subscribe(since: ContainerEventCursor?) async throws -> DockerEngineEvents {
        let subscription = try await ContainerClient().events(since: since)
        return DockerEngineEvents(
            processNonce: subscription.processNonce, cursor: subscription.cursor, gap: subscription.gap, events: subscription.events)
    }
}
