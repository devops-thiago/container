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
import ContainerLog
import ContainerizationOCI
import Logging

public struct K8sLoadImage: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "load-image",
        abstract: "Load a container image into every node of a cluster"
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    @Argument(help: "Image reference to load (e.g. demo-api:latest)")
    var image: String

    @Option(
        help: "Platform of the image to load (format: os/arch[/variant], default: linux/<host-arch>)"
    )
    var platform: String?

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        let results = try await K8sClusters.loadImage(
            image,
            cluster: name,
            platform: try platform.map { try Platform(from: $0) },
            log: log)
        for result in results where result.succeeded {
            print("\(result.node): loaded")
        }
        if let failure = K8sClusters.imageLoadFailure(image: image, cluster: name, results: results) {
            throw failure
        }
    }
}
