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

import ContainerResource
import ContainerizationError

/// The API can answer before the network helper has published its initialized default.
/// NetworkClient.list uses a one-second XPC response deadline and propagates cancellation.
public enum DefaultNetworkReadiness {
    public static func verify(
        networkIDs: @Sendable () async throws -> [String] = { try await NetworkClient().list().map(\.id) }
    ) async throws {
        try Task.checkCancellation()
        let ids = try await networkIDs()
        try Task.checkCancellation()
        guard ids.contains(NetworkClient.defaultNetworkName) else {
            throw ContainerizationError(.invalidState, message: "The default network is not ready; wait for engine startup and retry.")
        }
    }
}
