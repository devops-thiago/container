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

/// A container that belongs to a compose project, as the engine reports it.
public struct ComposeContainer: Sendable, Equatable {
    public enum State: String, Sendable {
        case running
        case stopped
        /// Between the two: being started or being stopped.
        case changing
    }

    public let id: String
    public let image: String
    /// The digest of the image the container was created from.
    public let imageDigest: String
    public let state: State
    /// How the container's process ended, once it has.
    public let exitCode: Int32?
    public let labels: [String: String]
    /// The container's published ports, as `host:container/protocol`.
    public let ports: [String]
    public let startedAt: Date?

    public init(
        id: String, image: String, imageDigest: String = "", state: State, exitCode: Int32? = nil, labels: [String: String],
        ports: [String] = [], startedAt: Date? = nil
    ) {
        self.id = id
        self.image = image
        self.imageDigest = imageDigest
        self.state = state
        self.exitCode = exitCode
        self.labels = labels
        self.ports = ports
        self.startedAt = startedAt
    }

    public var project: String? { labels[ComposeLabels.project] }
    public var service: String? { labels[ComposeLabels.service] }
    public var configHash: String? { labels[ComposeLabels.configHash] }
    public var dependencies: [ComposeDependency] { ComposeLabels.dependencies(from: labels[ComposeLabels.dependsOn] ?? "") }
    public var healthcheck: ComposeHealthcheck? { labels[ComposeLabels.healthcheck].flatMap(ComposeLabels.healthcheck(from:)) }
    public var stopTimeout: Int? { labels[ComposeLabels.stopGracePeriod].flatMap(Int.init) }
}

/// A container to make, as the command line that makes it.
public struct ContainerRequest: Sendable, Equatable {
    public let name: String
    public let image: String
    /// The options of `container run`, the name among them.
    public let options: [String]
    /// What follows the image: what the container runs.
    public let command: [String]
    /// The signal a stop sends, when it is not the image's.
    public let stopSignal: String?

    public init(name: String, image: String, options: [String], command: [String], stopSignal: String? = nil) {
        self.name = name
        self.image = image
        self.options = options
        self.command = command
        self.stopSignal = stopSignal
    }

    /// The whole `container run` command line, without the command's own name.
    public var arguments: [String] { options + [image] + command }
}

/// What compose asks of the engine. The live one talks to the API server; tests use one
/// that only remembers what it was asked.
public protocol ComposeEngine: Sendable {
    /// Every container labelled as part of `project`, in whatever state.
    func containers(project: String) async throws -> [ComposeContainer]
    /// The container with this name, whoever it belongs to.
    func container(named name: String) async throws -> ComposeContainer?

    func networkExists(_ name: String) async throws -> Bool
    func createNetwork(_ network: NetworkPlan) async throws
    func removeNetwork(_ name: String) async throws
    /// The networks compose made for `project`.
    func networks(project: String) async throws -> [String]

    func volumeExists(_ name: String) async throws -> Bool
    func createVolume(_ volume: VolumePlan) async throws
    func removeVolume(_ name: String) async throws
    func volumes(project: String) async throws -> [String]

    /// The digest of the image the reference names here, or nil when there is none.
    func imageDigest(_ reference: String) async throws -> String?
    /// Fetch the image from its registry whether or not it is here already. Returns the
    /// digest of what the reference names now.
    func pullImage(_ reference: String, platform: String?, progress: @escaping ProgressUpdateHandler) async throws -> String

    /// Make the container `container run` would make from the request, without starting
    /// it. Fetches the image when the options' pull policy calls for it.
    func createContainer(_ request: ContainerRequest, progress: @escaping ProgressUpdateHandler) async throws
    func startContainer(_ id: String) async throws
    func stopContainer(_ id: String, timeout: Int?) async throws
    func removeContainer(_ id: String) async throws

    /// Run a command in a running container and wait for it. nil when it has not ended
    /// within `timeout` seconds, in which case it is killed.
    func run(_ command: [String], in id: String, timeout: Double) async throws -> Int32?

    /// A host port nothing is listening on.
    func freeHostPort() async throws -> Int
}

/// Something compose did, or is doing, to one part of a project.
public struct ComposeEvent: Sendable, Equatable {
    public enum Subject: String, Sendable {
        case network
        case volume
        case image
        case container
    }

    public enum Status: String, Sendable {
        case creating, created, exists
        case recreating
        case pulling, pulled
        case building, built
        case starting, started, running
        case waiting, healthy, completed
        case stopping, stopped
        case removing, removed
        case failed
    }

    public let subject: Subject
    /// The network, volume, image or container.
    public let name: String
    /// The service it belongs to, for a container or an image.
    public let service: String?
    public let status: Status
    /// What a status alone does not say: what is waited for, or why something failed.
    public let detail: String?

    public init(_ subject: Subject, _ name: String, service: String? = nil, _ status: Status, detail: String? = nil) {
        self.subject = subject
        self.name = name
        self.service = service
        self.status = status
        self.detail = detail
    }
}

/// What a caller plugs into a compose run: where its events go, and the parts only the
/// caller can do.
public struct ComposeHooks: Sendable {
    /// Called with each step as it starts and ends.
    public var event: @Sendable (ComposeEvent) -> Void
    /// Progress of the image fetch for a service.
    public var progress: @Sendable (_ service: String) -> ProgressUpdateHandler
    /// Builds a service's image. nil means this caller cannot build, and a service that
    /// needs building fails with the command that would do it.
    public var build: (@Sendable (BuildPlan, _ service: String) async throws -> Void)?
    /// Something worth saying that is not a step: a container nobody asked about.
    public var warning: @Sendable (String) -> Void

    public init(
        event: @escaping @Sendable (ComposeEvent) -> Void = { _ in },
        progress: @escaping @Sendable (String) -> ProgressUpdateHandler = { _ in { _ in } },
        build: (@Sendable (BuildPlan, String) async throws -> Void)? = nil,
        warning: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.event = event
        self.progress = progress
        self.build = build
        self.warning = warning
    }
}
