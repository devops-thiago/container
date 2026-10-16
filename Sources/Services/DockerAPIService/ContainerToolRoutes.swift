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

import ContainerResource
import Foundation
import NIOHTTP1

/// Settings of the exec, logs, stats, top and archive routes.
public struct DockerToolOptions: Sendable {
    /// How often a followed log is looked at for new output.
    public var logPollInterval: Duration
    /// How often a followed log's container is looked at to see whether it still runs.
    public var logStatusInterval: Duration
    /// The time between two stats samples.
    public var statsInterval: Duration
    /// The largest archive an upload may send, and what its files may add up to.
    public var maxUploadBytes: Int
    /// The most entries an uploaded archive may have.
    public var maxUploadEntries: Int
    /// A monotonic clock in nanoseconds, which stats turn into the host CPU time dockerd
    /// reports.
    public var monotonicNanoseconds: @Sendable () -> UInt64
    /// The time a log line is stamped with: when it was read.
    public var now: @Sendable () -> Date

    public init(
        logPollInterval: Duration = .milliseconds(200), logStatusInterval: Duration = .seconds(1), statsInterval: Duration = .seconds(1),
        maxUploadBytes: Int = 1 << 30, maxUploadEntries: Int = 100_000,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.logPollInterval = logPollInterval
        self.logStatusInterval = logStatusInterval
        self.statsInterval = statsInterval
        self.maxUploadBytes = maxUploadBytes
        self.maxUploadEntries = maxUploadEntries
        self.monotonicNanoseconds = monotonicNanoseconds
        self.now = now
    }
}

/// The routes that work on a container's inside: exec, logs, stats, top, archive and export.
public enum ContainerToolRoutes {
    public static func register<Engine: EngineContainers & EngineContainerTools>(
        on router: inout DockerRouter, engine: Engine, identities: DockerIdentityStore, streams: DockerContainerStreams,
        options: DockerToolOptions = .init()
    ) {
        let routes = Routes(engine: engine, identities: identities, streams: streams, options: options)
        router.add(.POST, "/containers/{id}/exec") { request, parameters in try await routes.createExec(try parameters["id"], request) }
        router.add(.POST, "/exec/{id}/start") { request, parameters in try await routes.startExec(try parameters["id"], request) }
        router.add(.POST, "/exec/{id}/resize") { request, parameters in try await routes.resizeExec(try parameters["id"], request) }
        router.add(.GET, "/exec/{id}/json") { _, parameters in try await routes.inspectExec(try parameters["id"]) }
        router.add(.GET, "/containers/{id}/logs") { request, parameters in try await routes.logs(try parameters["id"], request) }
        router.add(.GET, "/containers/{id}/stats") { request, parameters in try await routes.stats(try parameters["id"], request) }
        router.add(.GET, "/containers/{id}/top") { request, parameters in try await routes.top(try parameters["id"], request) }
        router.add(.GET, "/containers/{id}/archive") { request, parameters in try await routes.archive(try parameters["id"], request) }
        router.add(.GET, "/containers/{id}/export") { _, parameters in try await routes.export(try parameters["id"]) }
        router.add(.PUT, "/containers/{id}/archive", body: .spool(maxBytes: options.maxUploadBytes)) { request, parameters in
            try await routes.extract(try parameters["id"], request)
        }
    }

    struct Routes<Engine: EngineContainers & EngineContainerTools>: Sendable {
        let engine: Engine
        let identities: DockerIdentityStore
        let streams: DockerContainerStreams
        let options: DockerToolOptions

        func find(_ reference: String) async throws -> DockerContainer {
            try DockerIdentityTable.resolve(reference, in: await identities.join(try await engine.list()))
        }

        /// `reference`'s container, refused as dockerd refuses one that is not running.
        func running(_ reference: String) async throws -> DockerContainer {
            let container = try await find(reference)
            guard ContainerViewMapper.isRunning(container.snapshot) else {
                throw DockerAPIError.conflict("container \(container.dockerID) is not running")
            }
            return container
        }
    }
}
