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
        abstract: "Create and start a local Kubernetes cluster and optional worker nodes",
        discussion: """
            --cpus and --memory size the control-plane node, or the single node if no workers are specified \
            (default 1/4 of host CPUs and memory, minimum 2 CPUs and 2g). \
            Size workers with --workers count=<n>,cpus=<n>,memory=<size>; a group's count defaults to 1, and cpus and memory left out default to the single-node sizes: 1/4 of host CPUs and memory (minimum 2 CPUs and 2g).
            """
    )

    @Option(name: .customLong("label"), help: "Set a key=value label on each node")
    var labels: [String] = []

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterCommandContext.defaultName

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

    @Option(
        name: .long,
        help: "Worker nodes to create: a number, or count=<n>,cpus=<n>,memory=<size> (repeat for groups of differently sized workers), 0...\(K8sClusters.maximumWorkers) in all",
        transform: { try WorkerGroup(parsing: $0) })
    var workers: [WorkerGroup] = []

    @Flag(help: "Let nodes pull images from the local image store")
    var sharedImageStore = false

    public func validate() throws {
        // Fail before anything is created, the same as invalid --workers values do.
        do {
            if let cpus = resourceFlags.cpus { _ = try Parser.cpus(cpus) }
            if let memory = resourceFlags.memory { _ = try Parser.memoryInBytes(memory) }
        } catch {
            throw ValidationError(wrapping: error)
        }

        var total: UInt = 0
        let maximum = UInt(K8sClusters.maximumWorkers)
        for group in workers {
            // Compare against the remaining room so the running total can't overflow.
            guard group.count <= maximum - total else {
                throw ValidationError("--workers must be between 0 and \(K8sClusters.maximumWorkers)")
            }
            total += group.count
        }
    }

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        // validate() has already bounded the total by K8sClusters.maximumWorkers.
        let workerCount = workers.reduce(0) { $0 + Int($1.count) }

        let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
        // TotalTasks include:
        // start, kubeadm init, one per worker, wait, write kubeconfig.
        let progressConfig = try ProgressConfig(
            showSpinner: isTTY,
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 4 + workerCount,
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
            workerGroups: workers.map {
                K8sClusters.WorkerGroup(count: Int($0.count), cpus: $0.cpus, memory: $0.memory)
            },
            cniManifestPath: cni,
            autoRemove: remove,
            sharedImageStore: sharedImageStore,
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
