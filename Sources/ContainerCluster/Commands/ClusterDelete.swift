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
import Logging

public struct ClusterDelete: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a Kubernetes cluster and its nodes",
        aliases: ["rm"]
    )

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterCommandContext.defaultName

    @Option(name: .customLong("require-label"), help: "Delete only nodes carrying this key=value label")
    var requiredLabels: [String] = []

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        try await K8sClusters.delete(
            name: name, requiredLabels: requiredLabels.isEmpty ? nil : Utility.parseKeyValuePairs(requiredLabels), log: log)
        print(name)
    }
}
