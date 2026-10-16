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

/// The engine as the container routes see it. The agent answers it from the API server; tests
/// answer it from a fake.
///
/// A method that fails for a reason a client should see throws a `DockerAPIError`; anything
/// else is answered as a 500 with the error's description.
public protocol EngineContainers: Sendable {
    /// Every container a Docker client may see, which leaves out the engine's own.
    func list() async throws -> [ContainerSnapshot]
    /// The engine's default network, which Docker calls `bridge`.
    func builtinNetwork() async throws -> String?
    /// The image a create names, or nil when it is not here: the client pulls it then, so a
    /// create never pulls.
    func image(_ reference: String, platform: String?) async throws -> DockerImageDefaults?
    /// The defaults the engine's configuration gives a new container.
    func createDefaults() async throws -> DockerCreateDefaults
    /// A free host port, for a port published without one.
    func allocatePort() throws -> UInt16
    /// Makes the plan's volumes, its init filesystem and the container. Returns the engine's
    /// incarnation of it.
    func create(_ plan: DockerCreatePlan) async throws -> String
    /// Bootstraps a created or stopped container's init process with `stdio`, ready to start.
    /// A failed bootstrap cleans up after itself.
    func bootstrap(_ container: ContainerSnapshot, stdio: DockerProcessStdio) async throws -> any EngineProcess
    /// One container by its engine ID, or nil when there is none: what `wait` polls.
    func get(_ engineID: String) async throws -> ContainerSnapshot?
    func stop(_ container: ContainerSnapshot, timeout: Int32, signal: String?) async throws
    func kill(_ container: ContainerSnapshot, signal: String) async throws
    func delete(_ container: ContainerSnapshot, force: Bool) async throws
    func deleteVolume(_ name: String) async throws
    /// Image ID by index digest, for the engine's images (see `DockerViewContext.imageIDs`).
    func imageIDs() async throws -> [String: String]
}

extension EngineContainers {
    /// No mapping: containers this service did not create show their index digest.
    public func imageIDs() async throws -> [String: String] { [:] }
}

/// The container routes: list, create, inspect, the lifecycle, rename and prune, and the streams
/// `docker run` needs: attach, wait and resize. Logs and the other streams are not here.
public enum ContainerRoutes {
    /// What dockerd waits for a container to stop before it kills it, when the client does not
    /// say.
    public static let defaultStopTimeout: Int32 = 10

    public static func register(
        on router: inout DockerRouter, engine: some EngineContainers, identities: DockerIdentityStore, streams: DockerContainerStreams,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let routes = Routes(engine: engine, identities: identities, streams: streams, now: now)
        router.add(.GET, "/containers/json") { request, _ in try await routes.list(request) }
        router.add(.POST, "/containers/create") { request, _ in try await routes.create(request) }
        router.add(.POST, "/containers/prune") { request, _ in try await routes.prune(request) }
        router.add(.GET, "/containers/{id}/json") { _, parameters in try await routes.inspect(try parameters["id"]) }
        router.add(.DELETE, "/containers/{id}") { request, parameters in try await routes.delete(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/start") { _, parameters in try await routes.start(try parameters["id"]) }
        router.add(.POST, "/containers/{id}/stop") { request, parameters in try await routes.stop(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/kill") { request, parameters in try await routes.kill(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/restart") { request, parameters in try await routes.restart(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/rename") { request, parameters in try await routes.rename(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/attach") { request, parameters in try await routes.attach(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/wait") { request, parameters in try await routes.wait(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/resize") { request, parameters in try await routes.resize(try parameters["id"], request) }
        for (action, reason) in [
            ("pause", "a container's VM cannot be paused"),
            ("unpause", "a container's VM cannot be paused"),
            ("update", "a container's resources are fixed when it is created"),
        ] {
            router.add(.POST, "/containers/{id}/\(action)") { _, _ in
                throw DockerAPIError.notImplemented("\(action) is not supported by SiliconShip: \(reason)")
            }
        }
        router.add(.POST, "/commit") { _, _ in
            throw DockerAPIError.notImplemented("commit is not supported by SiliconShip: build an image from a Dockerfile instead")
        }
    }

    struct Routes<Engine: EngineContainers>: Sendable {
        let engine: Engine
        let identities: DockerIdentityStore
        let streams: DockerContainerStreams
        let now: @Sendable () -> Date

        func containers() async throws -> [DockerContainer] {
            await identities.join(try await engine.list())
        }

        func context() async throws -> DockerViewContext {
            // An image list that fails costs foreign containers their config digest, not the view.
            DockerViewContext(now: now(), builtinNetwork: try await engine.builtinNetwork(), imageIDs: (try? await engine.imageIDs()) ?? [:])
        }

        func find(_ reference: String) async throws -> (DockerContainer, [DockerContainer]) {
            let all = try await containers()
            return (try DockerIdentityTable.resolve(reference, in: all), all)
        }

        func list(_ request: DockerRequest) async throws -> DockerResponse {
            let context = try await context()
            let filter = try ContainerListFilter(filters: try request.filters(), all: try request.bool("all"), limit: try request.int("limit"), context: context)
            return try .json(filter.apply(try await containers()).map { ContainerViewMapper.summary($0, context: context) })
        }

        func inspect(_ reference: String) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            return try .json(ContainerViewMapper.inspect(container, context: try await context()))
        }

        func create(_ request: DockerRequest) async throws -> DockerResponse {
            let body = try request.decode(DockerContainerCreateBody.self)
            guard let reference = body.config.Image, !reference.isEmpty else {
                throw DockerAPIError.badRequest("no image was given to create the container from")
            }
            let name = request.query("name").flatMap { $0.isEmpty ? nil : $0 }
            let existing = try await containers()
            let reservation = try await identities.reserve(name: name, among: existing)
            var generator = SystemRandomNumberGenerator()
            // A port published without a host port takes one no other container publishes,
            // running or not: a stopped container's port is free now and taken when it starts.
            var takenPorts = Set(
                existing.flatMap { container in
                    container.snapshot.configuration.publishedPorts.flatMap { port in (0..<port.count).map { port.hostPort &+ $0 } }
                })
            let allocatePort = { () throws -> UInt16 in
                for _ in 0..<64 {
                    let port = try engine.allocatePort()
                    if takenPorts.insert(port).inserted { return port }
                }
                throw DockerAPIError.internalError("no free host port was found for a port published without one")
            }
            do {
                guard let image = try await engine.image(reference, platform: request.query("platform").flatMap { $0.isEmpty ? nil : $0 }) else {
                    throw DockerAPIError.notFound("No such image: \(Self.taggedReference(reference))")
                }
                let plan = try ContainerCreateMapper.plan(
                    body, reservation: reservation, image: image, imageReference: reference, defaults: try await engine.createDefaults(),
                    allocatePort: allocatePort, newVolumeName: { DockerIdentityTable.randomID(using: &generator) })
                let incarnation = try await engine.create(plan)
                await identities.commit(reservation, incarnation: incarnation, extras: plan.extras)
                return try .json(DockerContainerCreateResponse(Id: reservation.dockerID, Warnings: plan.warnings), status: .created)
            } catch {
                await identities.release(reservation)
                throw error
            }
        }

        /// The reference with `:latest` when it names no tag or digest, as dockerd reports a
        /// missing image.
        static func taggedReference(_ reference: String) -> String {
            let last = reference.split(separator: "/").last ?? Substring(reference)
            return last.contains(":") || last.contains("@") ? reference : reference + ":latest"
        }

        func start(_ reference: String) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            if ContainerViewMapper.isRunning(container.snapshot) {
                return .empty(.notModified)
            }
            return try await start(container) == .started ? .empty() : .empty(.notModified)
        }

        /// Starts `container` with the attaches waiting for it. A container made with
        /// `--rm` that fails to start is removed, as dockerd removes it: `docker run --rm`
        /// waits for that removal before it reports the failure.
        func start(_ container: DockerContainer) async throws -> DockerContainerProcesses.StartOutcome {
            do {
                return try await streams.processes.start(container)
            } catch {
                if container.extras?.autoRemove == true {
                    try? await engine.delete(container.snapshot, force: true)
                    await removed(container.engineID, failure: DockerContainerProcesses.message(error))
                }
                throw error
            }
        }

        /// What follows a deletion: waits on it answer, attaches waiting for it go.
        func removed(_ engineID: String, failure: String? = nil) async {
            await identities.forget(engineID: engineID)
            await streams.waits.removed(engineID, failure: failure)
            await streams.attaches.release(engineID: engineID)
        }

        func stopTimeout(_ request: DockerRequest) throws(DockerAPIError) -> Int32 {
            guard let seconds = try request.int("t") else { return defaultStopTimeout }
            // -1 waits for as long as it takes.
            return seconds < 0 ? Int32.max : Int32(clamping: seconds)
        }

        func stop(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            guard ContainerViewMapper.isRunning(container.snapshot) else {
                return .empty(.notModified)
            }
            try await engine.stop(container.snapshot, timeout: try stopTimeout(request), signal: request.query("signal").flatMap { $0.isEmpty ? nil : $0 })
            return .empty()
        }

        func kill(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            guard ContainerViewMapper.isRunning(container.snapshot) else {
                throw DockerAPIError.conflict("cannot kill container: \(reference): container \(container.dockerID) is not running")
            }
            let signal = request.query("signal").flatMap { $0.isEmpty ? nil : $0 } ?? "KILL"
            try await engine.kill(container.snapshot, signal: signal)
            return .empty()
        }

        func restart(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            let timeout = try stopTimeout(request)
            do {
                if ContainerViewMapper.isRunning(container.snapshot) {
                    try await engine.stop(container.snapshot, timeout: timeout, signal: request.query("signal").flatMap { $0.isEmpty ? nil : $0 })
                }
                // The engine's snapshot after the stop, so that the start acts on the stopped
                // container rather than the running one seen before it.
                let stopped = try await containers().first { $0.engineID == container.engineID }
                guard let stopped else {
                    throw DockerAPIError.notFound("No such container: \(reference)")
                }
                _ = try await start(stopped)
            } catch let error as DockerAPIError {
                throw DockerAPIError(error.status, "Cannot restart container \(reference): \(error.message)")
            } catch {
                throw DockerAPIError.internalError("Cannot restart container \(reference): \(error)")
            }
            return .empty()
        }

        func rename(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, all) = try await find(reference)
            try await identities.rename(container, to: request.query("name") ?? "", among: all)
            return .empty()
        }

        func delete(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let force = try request.bool("force")
            let removeVolumes = try request.bool("v")
            let (container, _) = try await find(reference)
            if !force && ContainerViewMapper.isRunning(container.snapshot) {
                throw DockerAPIError.conflict(
                    "cannot remove container \"\(reference)\": container is \(ContainerViewMapper.status(container.snapshot).rawValue): stop the container before removing or force remove"
                )
            }
            try await engine.delete(container.snapshot, force: force)
            await removed(container.engineID)
            if removeVolumes {
                for volume in container.extras?.anonymousVolumes ?? [] {
                    // dockerd removes what it can and does not fail the delete over the rest.
                    try? await engine.deleteVolume(volume)
                }
            }
            return .empty()
        }

        func prune(_ request: DockerRequest) async throws -> DockerResponse {
            let filters = try request.filters()
            for key in filters.keys.sorted() where !["label", "label!"].contains(key) {
                throw key == "until" ? DockerAPIError.badRequest("the 'until' filter is not supported") : DockerAPIError.badRequest("invalid filter '\(key)'")
            }
            var deleted: [String] = []
            for container in try await containers() where !ContainerViewMapper.isRunning(container.snapshot) {
                let labels = container.snapshot.configuration.labels
                guard (filters["label"] ?? []).allSatisfy({ Self.labelMatches($0, labels) }),
                    !(filters["label!"] ?? []).contains(where: { Self.labelMatches($0, labels) })
                else { continue }
                do {
                    try await engine.delete(container.snapshot, force: false)
                } catch {
                    // dockerd skips a container it cannot remove and goes on with the rest.
                    continue
                }
                await removed(container.engineID)
                deleted.append(container.dockerID)
            }
            return try .json(DockerContainerPruneResponse(ContainersDeleted: deleted.isEmpty ? nil : deleted, SpaceReclaimed: 0))
        }

        static func labelMatches(_ condition: String, _ labels: [String: String]) -> Bool {
            let parts = condition.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let value = labels[String(parts[0])] else { return false }
            return parts.count == 1 || value == parts[1]
        }
    }
}
