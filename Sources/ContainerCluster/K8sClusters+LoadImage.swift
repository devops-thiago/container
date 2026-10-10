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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage

extension K8sClusters {
    /// What loading an image did on one node of a cluster.
    public struct NodeImageLoad: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// The image was imported, and tagged with the name the user gave when that differs
            /// from its normalized name.
            case loaded
            /// The node was not running, so nothing was attempted on it. The string is the
            /// node's container status, e.g. "stopped".
            case notRunning(String)
            /// The import or the tag failed. The string says why.
            case failed(String)
        }

        /// The node's container ID; the control plane's equals the cluster name.
        public let node: String
        public let role: String
        public let outcome: Outcome

        public var succeeded: Bool { outcome == .loaded }
    }

    /// How many nodes import the archive at once. Each import streams the whole archive
    /// into a node VM, so a cluster with many workers is loaded a few nodes at a time
    /// rather than all at once.
    static let maximumConcurrentImageImports = 4

    /// Save `image` from the local store once and import it into every node of a cluster,
    /// the control plane and each worker, so a pod finds it whichever node it lands on.
    ///
    /// Throws only when nothing could be attempted: the cluster is missing, the name is not
    /// a cluster, or the image could not be saved. Otherwise every node gets an outcome, and
    /// a node that failed or was not running does not stop the others. Pass the result to
    /// `imageLoadFailure(image:cluster:results:)` to turn any failure into one error.
    public static func loadImage(
        _ image: String,
        cluster name: String = K8sClusters.defaultName,
        platform: Platform? = nil,
        log: Logger
    ) async throws -> [NodeImageLoad] {
        let client = ContainerClient()
        // Resolve the nodes before saving, so a wrong name fails fast and leaves no archive.
        let nodes = try await nodesToLoad(cluster: name, containers: client)

        let archive = FilePath(FileManager.default.temporaryDirectory.path(percentEncoded: false))
            .appending("k8s-image-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(atPath: archive.string) }

        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
        let fq = K8sHelper.fqReference(image)
        let resolvedPlatform = try platform ?? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        log.info("Saving image", metadata: ["ref": "\(image)"])
        try await ClientImage.save(
            references: [fq], out: archive.string, platform: resolvedPlatform,
            containerSystemConfig: containerSystemConfig)

        return await importArchive(
            archive.string, image: image, into: nodes, containers: client, log: log)
    }

    /// The nodes of cluster `name` to load an image into: the control plane first, then the
    /// workers by ID, whatever their state, so a stopped node is reported rather than missed.
    static func nodesToLoad(
        cluster name: String,
        containers: any K8sNodeImageLoader
    ) async throws -> [ContainerSnapshot] {
        // Refuse a container this plugin does not own before touching anything.
        let named: ContainerSnapshot
        do {
            named = try await containers.get(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw ContainerizationError(.notFound, message: "k8s cluster \(name) not found")
        }
        guard named.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }
        let nodes = clusterNodes(cluster: name, listed: try await containers.listNodes())
        guard nodes.first?.id == name else {
            throw ContainerizationError(.notFound, message: "k8s cluster \(name) not found")
        }
        return nodes
    }

    /// The nodes of cluster `name` among `listed`, with the cluster's ownership rules from
    /// `k8s list`: the control plane first, then its workers ordered by ID. Empty when the
    /// listing has no control plane by that name.
    static func clusterNodes(cluster name: String, listed: [ContainerSnapshot]) -> [ContainerSnapshot] {
        let nodes = K8sHelper.buildK8sRows(from: listed)
            .filter { $0.clusterName == name }
            .map(\.snapshot)
        guard let controlPlane = nodes.first(where: { $0.id == name }) else { return [] }
        return [controlPlane] + nodes.filter { $0.id != name }.sorted { $0.id < $1.id }
    }

    /// Import the saved archive into each running node and tag it with the name the user
    /// gave when that differs from the normalized one, a few nodes at a time. Never throws: each node's failure is its own
    /// outcome, and the results come back in the order of `nodes`.
    static func importArchive(
        _ archivePath: String,
        image: String,
        into nodes: [ContainerSnapshot],
        containers: any K8sNodeImageLoader,
        maximumConcurrent: Int = K8sClusters.maximumConcurrentImageImports,
        log: Logger
    ) async -> [NodeImageLoad] {
        let fq = K8sHelper.fqReference(image)
        // The archive carries the normalized name. When the user wrote the reference
        // differently, the node also gets the name as written, as the single-node load did.
        let givenName = fq == image ? nil : image

        @Sendable func load(_ node: ContainerSnapshot) async -> NodeImageLoad.Outcome {
            guard node.status == .running else {
                return .notRunning(node.status.rawValue)
            }
            do {
                log.info("Importing image into node", metadata: ["node": "\(node.id)", "ref": "\(fq)"])
                try await containers.importImage(nodeID: node.id, archivePath: archivePath)
                if let givenName {
                    log.info("Tagging image for kubelet", metadata: ["node": "\(node.id)", "short": "\(givenName)", "fq": "\(fq)"])
                    try await containers.tagImage(nodeID: node.id, source: fq, target: givenName)
                }
                return .loaded
            } catch {
                return .failed(describe(error))
            }
        }

        var outcomes = [NodeImageLoad.Outcome?](repeating: nil, count: nodes.count)
        await withTaskGroup(of: (Int, NodeImageLoad.Outcome).self) { group in
            var pending = Array(nodes.enumerated()).makeIterator()
            for _ in 0..<max(1, maximumConcurrent) {
                guard let (index, node) = pending.next() else { break }
                group.addTask { (index, await load(node)) }
            }
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                if let (nextIndex, node) = pending.next() {
                    group.addTask { (nextIndex, await load(node)) }
                }
            }
        }

        return zip(nodes, outcomes).map { node, outcome in
            NodeImageLoad(
                node: node.id,
                role: node.configuration.labels[ResourceLabelKeys.role] ?? "",
                outcome: outcome ?? .failed("not attempted"))
        }
    }

    /// One error naming every node the image did not reach and why, or nil when every node
    /// has it.
    public static func imageLoadFailure(
        image: String,
        cluster name: String,
        results: [NodeImageLoad]
    ) -> ContainerizationError? {
        let missed = results.filter { !$0.succeeded }
        guard !missed.isEmpty else { return nil }
        let reasons = missed.map { result -> String in
            switch result.outcome {
            case .loaded:
                return result.node
            case .notRunning(let state):
                return "\(result.node) is not running (\(state)); start the cluster and load the image again"
            case .failed(let reason):
                return "\(result.node): \(reason)"
            }
        }
        let anyExecFailed = missed.contains {
            if case .failed = $0.outcome { return true }
            return false
        }
        return ContainerizationError(
            anyExecFailed ? .internalError : .invalidState,
            message: "image \(image) was not loaded into \(missed.count) of \(results.count) nodes of cluster \(name): "
                + reasons.joined(separator: "; "))
    }

    /// The error's message with its cause, so a failure the client wraps, such as a node
    /// whose runtime is not up yet, still says what went wrong underneath.
    private static func describe(_ error: any Error) -> String {
        if let error = error as? ContainerizationError { return error.localizedDescription }
        return "\(error)"
    }
}

/// What loading an image into a cluster needs from the engine, so a test can stand in for it.
protocol K8sNodeImageLoader: Sendable {
    func get(id: String) async throws -> ContainerSnapshot
    func listNodes() async throws -> [ContainerSnapshot]
    /// Run `ctr images import` in the node with the archive as its standard input.
    func importImage(nodeID: String, archivePath: String) async throws
    /// Run `ctr images tag` in the node, replacing `target` if it already exists so a
    /// reload of a rebuilt image moves that name too.
    func tagImage(nodeID: String, source: String, target: String) async throws
}

extension ContainerClient: K8sNodeImageLoader {
    private static let ctrPath = "/usr/local/bin/ctr"

    func importImage(nodeID: String, archivePath: String) async throws {
        guard let input = FileHandle(forReadingAtPath: archivePath) else {
            throw ContainerizationError(.internalError, message: "failed to open image archive \(archivePath)")
        }
        defer { try? input.close() }
        try await runCtr(
            nodeID: nodeID,
            arguments: ["--namespace", "k8s.io", "images", "import", "-"],
            stdin: input,
            what: "ctr import")
    }

    func tagImage(nodeID: String, source: String, target: String) async throws {
        try await runCtr(
            nodeID: nodeID,
            arguments: ["--namespace", "k8s.io", "images", "tag", "--force", source, target],
            stdin: nil,
            what: "ctr tag")
    }

    /// Run ctr in a node with its output in a temporary file, so a failure can say what
    /// ctr printed without a pipe reader blocking a thread while it runs.
    private func runCtr(
        nodeID: String,
        arguments: [String],
        stdin: FileHandle?,
        what: String
    ) async throws {
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("k8s-ctr-\(UUID().uuidString).log").path(percentEncoded: false)
        guard FileManager.default.createFile(atPath: outputPath, contents: nil),
            let output = FileHandle(forWritingAtPath: outputPath)
        else {
            throw ContainerizationError(.internalError, message: "failed to create \(outputPath)")
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let process = try await createProcess(
            containerId: nodeID,
            processId: UUID().uuidString.lowercased(),
            configuration: ProcessConfiguration(
                executable: Self.ctrPath, arguments: arguments, environment: [], terminal: false),
            stdio: [stdin, output, output])
        try await process.start()
        let code = try await process.wait()
        guard code == 0 else {
            let printed = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
            let tail = printed.split(whereSeparator: \.isNewline).suffix(5).joined(separator: " / ")
            throw ContainerizationError(
                .internalError,
                message: "\(what) exited \(code) on \(nodeID)" + (tail.isEmpty ? "" : ": \(tail)"))
        }
    }
}
