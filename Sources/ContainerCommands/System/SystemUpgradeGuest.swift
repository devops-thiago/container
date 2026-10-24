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

import ArgumentParser
import ContainerAPIClient

extension Application {
    public struct SystemUpgradeGuest: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "upgrade-guest",
            abstract: "Update a stopped container's guest agent, preserving its workload data")

        @Argument(help: "Container ID or name; the container must be stopped")
        var container: String

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let client = ContainerClient()
            let observed = try await client.get(id: container)
            try await client.upgradeGuest(id: observed.id, expectedIncarnation: observed.incarnation)
            print("Updated guest image for \(observed.id). Start the container to use it.")
        }
    }
}
