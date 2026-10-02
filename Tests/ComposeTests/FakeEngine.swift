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

import Foundation
import TerminalProgress
import Testing

@testable import ContainerCompose

/// An engine that only remembers: what exists, and what it was asked to do, in order.
final class FakeEngine: ComposeEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: ComposeContainer] = [:]
    private var projectNetworks: [String: String?] = [:]
    private var projectVolumes: [String: String?] = [:]
    private var localImages: Set<String> = []
    private var log: [String] = []
    private var created: [String: [String]] = [:]
    private var nextPort = 49152

    /// The exit codes a container's health check gives, one per run; the last one repeats.
    var probes: [String: [Int32?]] = [:]
    /// Containers whose process ends at once when started, and how.
    var exits: [String: Int32] = [:]
    /// Containers whose process ends after it has been looked at this many times.
    var exitsLater: [String: (looks: Int, code: Int32)] = [:]
    /// The digest a pull of an image returns.
    var digests: [String: String] = [:]
    var failingStarts: Set<String> = []
    /// Called while a container is being made, before it exists.
    var whileCreating: (@Sendable (String) -> Void)?

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var calls: [String] { locked { log } }
    func clearCalls() { locked { log.removeAll() } }
    func arguments(of container: String) -> [String] { locked { created[container] ?? [] } }
    func state(of container: String) -> ComposeContainer.State? { locked { stored[container]?.state } }
    var containerNames: [String] { locked { stored.keys.sorted() } }
    var networkNames: [String] { locked { projectNetworks.keys.sorted() } }
    var volumeNames: [String] { locked { projectVolumes.keys.sorted() } }

    func add(_ container: ComposeContainer) { locked { stored[container.id] = container } }
    func addNetwork(_ name: String, project: String? = nil) { locked { projectNetworks[name] = project } }
    func addVolume(_ name: String, project: String? = nil) { locked { projectVolumes[name] = project } }
    func addImage(_ reference: String) { locked { _ = localImages.insert(reference) } }

    func containers(project: String) async throws -> [ComposeContainer] {
        locked { stored.values.filter { $0.project == project }.sorted { $0.id < $1.id } }
    }

    func container(named name: String) async throws -> ComposeContainer? {
        locked {
            if let container = stored[name], container.state == .running, let later = exitsLater[name] {
                if later.looks <= 0 {
                    exitsLater.removeValue(forKey: name)
                    stored[name] = ComposeContainer(
                        id: name, image: container.image, imageDigest: container.imageDigest, state: .stopped, exitCode: later.code,
                        labels: container.labels, ports: container.ports)
                } else {
                    exitsLater[name] = (later.looks - 1, later.code)
                }
            }
            return stored[name]
        }
    }

    func networkExists(_ name: String) async throws -> Bool { locked { projectNetworks[name] != nil } }

    func createNetwork(_ network: NetworkPlan) async throws {
        locked {
            log.append("network create \(network.name)")
            projectNetworks[network.name] = network.labels[ComposeLabels.project]
        }
    }

    func removeNetwork(_ name: String) async throws {
        locked {
            log.append("network remove \(name)")
            projectNetworks.removeValue(forKey: name)
        }
    }

    func networks(project: String) async throws -> [String] {
        locked { projectNetworks.filter { $0.value == project }.keys.sorted() }
    }

    func volumeExists(_ name: String) async throws -> Bool { locked { projectVolumes[name] != nil } }

    func createVolume(_ volume: VolumePlan) async throws {
        locked {
            log.append("volume create \(volume.name)")
            projectVolumes[volume.name] = volume.labels[ComposeLabels.project]
        }
    }

    func removeVolume(_ name: String) async throws {
        locked {
            log.append("volume remove \(name)")
            projectVolumes.removeValue(forKey: name)
        }
    }

    func volumes(project: String) async throws -> [String] {
        locked { projectVolumes.filter { $0.value == project }.keys.sorted() }
    }

    func imageDigest(_ reference: String) async throws -> String? {
        locked { localImages.contains(reference) ? digests[reference] ?? "sha256:local" : nil }
    }

    func pullImage(_ reference: String, platform: String?, progress: @escaping ProgressUpdateHandler) async throws -> String {
        locked {
            log.append("pull \(reference)")
            localImages.insert(reference)
            return digests[reference] ?? "sha256:pulled"
        }
    }

    func createContainer(_ request: ContainerRequest, progress: @escaping ProgressUpdateHandler) async throws {
        whileCreating?(request.name)
        // The engine's own calls give up when the task they are in is cancelled.
        try Task.checkCancellation()
        var labels: [String: String] = [:]
        for label in ArgumentList.values(of: "--label", in: request.options) {
            let parts = label.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            labels[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        locked {
            log.append("create \(request.name)")
            created[request.name] = request.arguments
            // Making a container fetches its image when it is not here.
            localImages.insert(request.image)
            stored[request.name] = ComposeContainer(
                id: request.name, image: request.image, imageDigest: digests[request.image] ?? "sha256:local", state: .stopped,
                labels: labels, ports: ArgumentList.values(of: "--publish", in: request.options))
        }
    }

    func startContainer(_ id: String) async throws {
        try locked {
            log.append("start \(id)")
            guard let container = stored[id] else { throw ComposeError("no container \(id)") }
            guard !failingStarts.contains(id) else { throw ComposeError("the engine could not start \(id)") }
            let exit = exits[id]
            stored[id] = ComposeContainer(
                id: id, image: container.image, imageDigest: container.imageDigest, state: exit == nil ? .running : .stopped, exitCode: exit,
                labels: container.labels, ports: container.ports)
        }
    }

    func stopContainer(_ id: String, timeout: Int?) async throws {
        locked {
            log.append("stop \(id)" + (timeout.map { " in \($0)s" } ?? ""))
            guard let container = stored[id] else { return }
            stored[id] = ComposeContainer(
                id: id, image: container.image, imageDigest: container.imageDigest, state: .stopped, exitCode: 0, labels: container.labels,
                ports: container.ports)
        }
    }

    func removeContainer(_ id: String) async throws {
        locked {
            log.append("remove \(id)")
            stored.removeValue(forKey: id)
        }
    }

    func run(_ command: [String], in id: String, timeout: Double) async throws -> Int32? {
        locked {
            log.append("probe \(id)")
            guard var results = probes[id], !results.isEmpty else { return 0 }
            let result = results.count > 1 ? results.removeFirst() : results[0]
            probes[id] = results
            return result
        }
    }

    func freeHostPort() async throws -> Int {
        locked {
            defer { nextPort += 1 }
            return nextPort
        }
    }
}

/// What a run reported, in order.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ComposeEvent] = []
    private var recordedWarnings: [String] = []
    private var recordedBuilds: [String] = []

    var events: [String] {
        lock.withLock {
            recordedEvents.map { "\($0.subject.rawValue) \($0.name) \($0.status.rawValue)" + ($0.detail.map { " (\($0))" } ?? "") }
        }
    }
    var warnings: [String] { lock.withLock { recordedWarnings } }
    var builds: [String] { lock.withLock { recordedBuilds } }

    func hooks(building: Bool = false) -> ComposeHooks {
        var hooks = ComposeHooks(
            event: { event in self.lock.withLock { self.recordedEvents.append(event) } },
            warning: { warning in self.lock.withLock { self.recordedWarnings.append(warning) } })
        if building {
            hooks.build = { build, service in self.lock.withLock { self.recordedBuilds.append("\(service): \(build.tag)") } }
        }
        return hooks
    }
}

/// Time that passes only when something sleeps.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    var now: Double { lock.withLock { seconds } }
    func advance(_ interval: Double) { lock.withLock { seconds += interval } }
}

struct ComposeRun {
    let engine = FakeEngine()
    let recorder = Recorder()
    let clock = FakeClock()

    func project(_ name: String = "shop", building: Bool = false) -> ComposeProject {
        var project = ComposeProject(name: name, engine: engine, hooks: recorder.hooks(building: building))
        let clock = self.clock
        project.readiness = Readiness(now: { clock.now }, sleep: { clock.advance($0) }, pollInterval: 1)
        project.pathExists = { _ in true }
        return project
    }

    func plan(_ yaml: String, named name: String = "shop", services: [String] = [], files: [String: String] = [:]) throws -> ProjectPlan {
        var all = files
        all["compose.yaml"] = yaml
        let temporary = try TemporaryProject(all, named: name)
        return try ProjectPlan.make(try temporary.load(), selection: .init(services: services))
    }
}
