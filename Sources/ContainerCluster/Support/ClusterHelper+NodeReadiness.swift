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
import ContainerResource
import ContainerizationError
import Foundation

extension ClusterHelper {
    // MARK: - Node readiness

    /// What the API server holds for one node's Ready condition.
    struct NodeReadyReport: Equatable, Sendable {
        let name: String
        let ready: Bool
        /// When the node's kubelet last wrote the condition, by the node's own clock.
        let heartbeat: Date?
    }

    /// A node a start brought back, and when its VM booted by its own clock.
    struct StartedNode: Equatable, Sendable {
        let name: String
        let bootedAt: Date
    }

    /// The nodes that keep a cluster from being Ready, each with what is missing.
    ///
    /// The API server keeps a stopped node's conditions, so right after a start it still
    /// answers Ready=True for every node, from before the stop. A started node counts only
    /// once its kubelet has written the condition since the node booted. Both times come
    /// from that node's clock, so neither the Mac's clock nor another node's is compared.
    /// Other nodes need only be Ready, as on a create.
    static func unreadyNodes(reports: [NodeReadyReport], started: [StartedNode]) -> [String] {
        var unready: [String] = []
        for node in started {
            guard let report = reports.first(where: { $0.name == node.name }) else {
                unready.append("\(node.name): not registered")
                continue
            }
            if !report.ready {
                unready.append("\(node.name): not Ready")
            } else if report.heartbeat.map({ $0 < node.bootedAt }) ?? true {
                unready.append("\(node.name): no report since it booted")
            }
        }
        let expected = Set(started.map(\.name))
        for report in reports where !expected.contains(report.name) && !report.ready {
            unready.append("\(report.name): not Ready")
        }
        return unready
    }

    /// One line per node: its name, then the Ready condition's status and heartbeat. The
    /// condition is picked with a filter, not a nested range: kubectl fails the whole
    /// template on a range over the conditions of a node that has none yet.
    static let nodeReadyTemplate =
        #"{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}"#
        + #"{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}{"\n"}{end}"#

    /// Reads `kubectl get nodes -o jsonpath=<nodeReadyTemplate>`. A node with no Ready
    /// condition yet has empty fields after its name, and is reported as not Ready.
    static func parseNodeReadyReports(_ output: String) -> [NodeReadyReport] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let heartbeat = fields.count > 2 ? try? Date(fields[2], strategy: .iso8601) : nil
            return NodeReadyReport(name: name, ready: fields.count > 1 && fields[1] == "True", heartbeat: heartbeat)
        }
    }

    /// Prints when the kernel booted, in seconds since the epoch by the guest's clock.
    static let bootTimeScript = "sed -n 's/^btime //p' /proc/stat"

    static func parseBootTime(_ output: String) -> Date? {
        guard let seconds = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Every node's Ready condition, or nil when kubectl got no answer.
    static func nodeReadyReports(
        containerId: String, client: ContainerClient, deadline: ContinuousClock.Instant
    ) async throws -> [NodeReadyReport]? {
        let result = try await capture(
            containerId: containerId, executable: kubectlPath,
            arguments: ["get", "nodes", "--request-timeout=2s", "-o", "jsonpath=\(nodeReadyTemplate)"],
            environment: [kubeconfigEnv], client: client, deadline: deadline)
        return result.code == 0 ? parseNodeReadyReports(result.output) : nil
    }

    /// When the node's VM booted. Each start of a node is a new boot.
    static func nodeBootTime(containerId: String, client: ContainerClient) async throws -> Date {
        let result = try await capture(
            containerId: containerId, executable: "/bin/sh", arguments: ["-c", bootTimeScript],
            environment: [], client: client, deadline: .now.advanced(by: .seconds(30)))
        guard result.code == 0, let booted = parseBootTime(result.output) else {
            throw ContainerizationError(
                .internalError, message: "failed to read when node \(containerId) booted: exit \(result.code)")
        }
        return booted
    }

    /// Runs a command in a node and returns what it wrote to stdout. The deadline bounds
    /// the command and the reading of its output, and a command that outlives it is killed.
    private static func capture(
        containerId: String, executable: String, arguments: [String], environment: [String],
        client: ContainerClient, deadline: ContinuousClock.Instant
    ) async throws -> (code: Int32, output: String) {
        // Named here, so the command can be killed whether or not its create or start answers.
        let processId = UUID().uuidString.lowercased()
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        defer { try? devNull?.close() }
        return try await capture(
            deadline: deadline,
            launch: { stdout in
                let process = try await client.createProcess(
                    containerId: containerId, processId: processId,
                    configuration: ProcessConfiguration(
                        executable: executable, arguments: arguments, environment: environment, terminal: false),
                    stdio: [nil, stdout, devNull], deadline: deadline)
                try await process.start()
                return { try await process.wait() }
            },
            kill: {
                try await client.killProcess(
                    containerId: containerId, processId: processId, signal: SIGKILL, responseTimeout: cleanupReplyTimeout)
            })
    }

    /// How long one kill sent in cleanup waits for its reply.
    static let cleanupReplyTimeout: Duration = .seconds(10)

    /// Runs what `launch` starts with its stdout on a pipe, and returns its exit code and
    /// output. `launch` returns how to wait for the command.
    ///
    /// A launch that fails may have started the command all the same: the request can reach
    /// the node and only its reply be late or given up on. So a failed launch is cleaned up
    /// as a command that outlived its deadline is, with `kill`, which is not waited for.
    static func capture(
        deadline: ContinuousClock.Instant,
        launch: (FileHandle) async throws -> @Sendable () async throws -> Int32,
        kill: @Sendable @escaping () async throws -> Void,
        cleanupPause: Duration = .seconds(1)
    ) async throws -> (code: Int32, output: String) {
        let cleanup: @Sendable () async -> Void = { await killUntilSent(kill, pause: cleanupPause) }
        let pipe = Pipe()
        let wait: @Sendable () async throws -> Int32
        do {
            wait = try await launch(pipe.fileHandleForWriting)
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            Task.detached { await cleanup() }
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        // The drain reads its own descriptor, so the pipe's handle can go now.
        let descriptor = dup(pipe.fileHandleForReading.fileDescriptor)
        try? pipe.fileHandleForReading.close()
        guard descriptor >= 0 else {
            Task.detached { await cleanup() }
            throw ContainerizationError(.internalError, message: "failed to read the output of a command in a node")
        }
        return try await collect(from: PipeDrain(owning: descriptor), deadline: deadline, wait: wait, kill: cleanup)
    }

    /// Sends `kill` until one is accepted, three times at most.
    ///
    /// A start whose reply was given up on can still take effect a moment later, and a kill
    /// that arrives before it is refused, as is one for a command that was never created.
    /// The tries are few and paused, so a command that does not exist costs little.
    static func killUntilSent(_ kill: @Sendable () async throws -> Void, pause: Duration, attempts: Int = 3) async {
        for attempt in 1...attempts {
            do {
                try await kill()
                return
            } catch {
                guard attempt < attempts else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }
}
