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
import ContainerLog
import ContainerResource
import ContainerizationError
import Foundation
import Logging

public struct ClusterStart: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a stopped Kubernetes cluster"
    )

    @Option(name: .long, help: "Cluster name (default: \(ClusterCommandContext.defaultName))")
    var name: String = ClusterCommandContext.defaultName

    @Flag(name: .long, help: "Explicitly adopt existing cluster nodes for writable /sys, preserving their data")
    var adoptLegacy = false

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        try await K8sClusters.start(name: name, adoptLegacy: adoptLegacy, log: log)
        print(name)
    }
}
