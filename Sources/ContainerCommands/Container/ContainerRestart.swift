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
import ContainerResource
import Foundation

extension Application {
    /// Stop, then start: the two existing commands in a row, one container at a time, so a
    /// container that fails to come back is named and the ones after it are left alone.
    public struct ContainerRestart: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Stop and start one or more containers")

        @Option(name: .shortAndLong, help: "Signal to send to the containers")
        var signal: String?

        @Option(name: .shortAndLong, help: "Seconds to wait before killing the containers")
        var time: Int32 = 5

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String]

        public func validate() throws {
            if containerIds.isEmpty {
                throw ValidationError("no containers specified")
            }
        }

        public func run() async throws {
            let client = ContainerClient()
            let options = ContainerStopOptions(timeoutInSeconds: time, signal: signal)
            for id in containerIds {
                try await client.stop(id: id, opts: options)
                // `start` prints the id once it is up, which is restart's whole output too.
                let start = try ContainerStart.parse([id])
                try await start.run()
            }
        }
    }
}
