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
import Foundation

extension Application {
    /// The prune commands in a row: stopped containers, networks nothing is attached to and
    /// dangling images. Volumes hold data, so they are pruned only when asked for, and then
    /// only the anonymous ones, as `volume prune` does without `--all`.
    public struct SystemPrune: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove stopped containers, unused networks and dangling images")

        @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
        var all = false

        @Flag(name: .long, help: "Remove anonymous volumes with no container references too")
        var volumes = false

        @OptionGroup
        var confirmation: PruneConfirmation

        @OptionGroup
        public var logOptions: Flags.Logging

        /// The command lines this one stands for, in the order they run.
        static func steps(all: Bool, volumes: Bool, debug: Bool = false, networks: Bool = Self.hasNetworks) -> [[String]] {
            // --debug goes first: the parser takes it only ahead of a command's own flags.
            let logging = debug ? ["--debug"] : []
            var steps: [[String]] = [["prune"] + logging]
            if networks { steps.append(["network", "prune"] + logging) }
            steps.append(["image", "prune"] + logging + (all ? ["--all"] : []))
            if volumes { steps.append(["volume", "prune"] + logging) }
            return steps
        }

        /// User-defined networks, and the command that prunes them, need macOS 26.
        static var hasNetworks: Bool {
            if #available(macOS 26, *) { return true }
            return false
        }

        public func run() async throws {
            for step in Self.steps(all: all, volumes: volumes, debug: logOptions.debug) {
                var command = try Application.parseAsRoot(step)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            }
        }
    }
}
