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
import Darwin
import Foundation
import Logging
import TerminalProgress

public struct ClusterCreate: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create and start a local Kubernetes cluster and optional worker nodes"
    )

    @Option(name: .customLong("label"), help: "Set a key=value label on each node")
    var labels: [String] = []

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterHelper.defaultName

    @Flag(name: [.customLong("rm"), .long], help: "Remove the cluster container after it stops")
    var remove: Bool = false

    @OptionGroup(title: "Resource options")
    var resourceFlags: Flags.Resource

    @OptionGroup(title: "Registry options")
    var registryFlags: Flags.Registry

    @OptionGroup(title: "Image fetch options")
    var imageFetchFlags: Flags.ImageFetch

    @Option(help: "Node image reference")
    var nodeImage: String = ClusterHelper.nodeImage

    @Option(name: .long, help: "Optional path to a CNI manifest to apply, or \"NONE\" to skip installing a CNI.")
    var cni: String?

    @Option(name: .long, help: "Number of worker nodes to create, 0...\(K8sClusters.maximumWorkers)")
    var workers: Int = 0

    public func validate() throws {
        guard (0...K8sClusters.maximumWorkers).contains(workers) else {
            throw ValidationError("--workers must be between 0 and \(K8sClusters.maximumWorkers)")
        }
    }

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
        // TotalTasks include:
        // start, kubeadm init, one per worker, wait, write kubeconfig.
        let progressConfig = try ProgressConfig(
            showSpinner: isTTY,
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 4 + workers,
            clearOnFinish: isTTY,
            outputMode: isTTY ? .ansi : .plain
        )

        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let result = try await K8sClusters.create(
            name: name,
            labels: Utility.parseKeyValuePairs(labels),
            nodeImage: nodeImage,
            cpus: resourceFlags.cpus,
            memory: resourceFlags.memory,
            workers: workers,
            cniManifestPath: cni,
            autoRemove: remove,
            registry: registryFlags,
            imageFetch: imageFetchFlags,
            log: log,
            progressUpdate: progress.handler
        )

        progress.finish()
        if !result.kubeconfigWritten {
            log.info("cluster is running; use 'container cluster write-config --name \(name)' to write the kubeconfig")
        }
        print(name)
    }
}
