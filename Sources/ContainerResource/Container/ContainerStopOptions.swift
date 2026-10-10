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

public struct ContainerStopOptions: Sendable, Codable {
    public var timeoutInSeconds: Int32
    public var signal: String?
    /// The stop is the engine going down (its app quitting or stopping it), not a person
    /// stopping this container. Such a stop does not count as the user's for the restart
    /// policy: an `unless-stopped` container stopped this way starts again with the engine,
    /// as Docker's do when its daemon restarts. Either kind of stop ends any restart in
    /// progress.
    public var engineShutdown: Bool

    public static let `default` = ContainerStopOptions(
        timeoutInSeconds: 5,
        signal: nil
    )

    public init(timeoutInSeconds: Int32, signal: String?, engineShutdown: Bool = false) {
        self.timeoutInSeconds = timeoutInSeconds
        self.signal = signal
        self.engineShutdown = engineShutdown
    }

    private enum CodingKeys: String, CodingKey {
        case timeoutInSeconds
        case signal
        case engineShutdown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeoutInSeconds = try container.decode(Int32.self, forKey: .timeoutInSeconds)
        signal = try container.decodeIfPresent(String.self, forKey: .signal)
        engineShutdown = try container.decodeIfPresent(Bool.self, forKey: .engineShutdown) ?? false
    }
}
