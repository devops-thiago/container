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

/// `container version` and `container info`: the two system commands a person checks first,
/// spelled at the root. Each is the existing command behind another name, and stays out of
/// the root's help, which lists `system`.
extension Application {
    static let systemRootSpellings: [any ParsableCommand.Type] = [Version.self, Info.self]

    public struct Version: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "version", abstract: "Show version information (the same as system version)", shouldDisplay: false)
        @OptionGroup var command: SystemVersion
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }

    public struct Info: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "info", abstract: "Show the status of the system (the same as system status)", shouldDisplay: false)
        @OptionGroup var command: SystemStatus
        public var logOptions: Flags.Logging { command.logOptions }
        public func run() async throws { try await command.run() }
    }
}
