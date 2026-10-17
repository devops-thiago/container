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
import Logging
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
    ///
    /// `requester` is who the engine's folder panel names for a bind mount it has to ask for:
    /// the client that sent the request (`DockerPeer.requester`), or nil when it is not known.
    func create(_ plan: DockerCreatePlan, requester: String?) async throws -> String
    /// Bootstraps a created or stopped container's init process with `stdio`, ready to start.
    /// A failed bootstrap cleans up after itself. `requester` is as `create` takes it.
    func bootstrap(_ container: ContainerSnapshot, stdio: DockerProcessStdio, requester: String?) async throws -> any EngineProcess
    /// One container by its engine ID, or nil when there is none: what `wait` polls.
    func get(_ engineID: String) async throws -> ContainerSnapshot?
    func stop(_ container: ContainerSnapshot, timeout: Int32, signal: String?) async throws
    func kill(_ container: ContainerSnapshot, signal: String) async throws
    func delete(_ container: ContainerSnapshot, force: Bool) async throws
    func deleteVolume(_ name: String) async throws
    /// Image ID by index digest, for the engine's images (see `DockerViewContext.imageIDs`).
    func imageIDs() async throws -> [String: String]
    /// Whether the engine keeps a container's name, so that a rename is the engine's to make.
    /// An engine from before it did answers false, and a rename is this service's alone.
    func supportsRename() async -> Bool
    /// Sets the container's name label (`DockerLabels.name`) in the engine: the only label the
    /// engine lets change.
    func rename(_ container: ContainerSnapshot, to name: String) async throws
    /// What the container wrote to its root filesystem, as dockerd reports `SizeRw`, or nil
    /// when the engine cannot tell without a larger figure than dockerd's (while it runs, for
    /// one).
    func writableSize(_ container: ContainerSnapshot) async -> Int64?
}

extension EngineContainers {
    /// No mapping: containers this service did not create show their index digest.
    public func imageIDs() async throws -> [String: String] { [:] }

    public func supportsRename() async -> Bool { false }

    public func rename(_ container: ContainerSnapshot, to name: String) async throws {
        throw DockerAPIError.notImplemented("the engine cannot rename a container")
    }

    /// An engine that cannot measure it says nothing.
    public func writableSize(_ container: ContainerSnapshot) async -> Int64? { nil }
}

/// The container routes: list, create, inspect, the lifecycle, rename and prune, and the streams
/// `docker run` needs: attach, wait and resize. Logs and the other streams are not here.
public enum ContainerRoutes {
    /// What dockerd waits for a container to stop before it kills it, when the client does not
    /// say.
    public static let defaultStopTimeout: Int32 = 10

    /// - Parameter events: where the changes these routes make are reported, as they make
    ///   them; nil reports nothing.
    public static func register(
        on router: inout DockerRouter, engine: some EngineContainers, identities: DockerIdentityStore, streams: DockerContainerStreams,
        now: @escaping @Sendable () -> Date = { Date() }, events: DockerEventBus? = nil
    ) {
        let routes = Routes(engine: engine, identities: identities, streams: streams, now: now, events: events)
        router.add(.GET, "/containers/json") { request, _ in try await routes.list(request) }
        router.add(.POST, "/containers/create") { request, _ in try await routes.create(request) }
        router.add(.POST, "/containers/prune") { request, _ in try await routes.prune(request) }
        router.add(.GET, "/containers/{id}/json") { request, parameters in try await routes.inspect(try parameters["id"], request) }
        router.add(.DELETE, "/containers/{id}") { request, parameters in try await routes.delete(try parameters["id"], request) }
        router.add(.POST, "/containers/{id}/start") { request, parameters in try await routes.start(try parameters["id"], request) }
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

    /// Gives the engine the names renamed here while it could not keep them, so that its name
    /// label, which every client reads, has them. Nothing when it still cannot; a name it
    /// refuses (another container took it in the engine meanwhile) stays here.
    public static func moveLocalRenamesToEngine(engine: some EngineContainers, identities: DockerIdentityStore, log: Logger) async {
        guard await engine.supportsRename(), let snapshots = try? await engine.list() else { return }
        for (container, name) in await identities.localRenames(snapshots) {
            do {
                try await engine.rename(container.snapshot, to: name)
                await identities.renamedInEngine(container, to: name)
            } catch {
                log.warning("could not give the engine a container's name", metadata: ["container": "\(container.engineID)", "error": "\(error)"])
            }
        }
    }

    struct Routes<Engine: EngineContainers>: Sendable {
        let engine: Engine
        let identities: DockerIdentityStore
        let streams: DockerContainerStreams
        let now: @Sendable () -> Date
        let events: DockerEventBus?

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

        /// `size=1` adds each container's `SizeRw`, where the engine can tell it.
        func list(_ request: DockerRequest) async throws -> DockerResponse {
            let context = try await context()
            let filter = try ContainerListFilter(filters: try request.filters(), all: try request.bool("all"), limit: try request.int("limit"), context: context)
            let sized = try request.bool("size")
            var summaries: [DockerContainerSummary] = []
            for container in filter.apply(try await containers()) {
                var summary = ContainerViewMapper.summary(container, context: context)
                if sized { summary.SizeRw = ContainerViewMapper.listedSize(await engine.writableSize(container.snapshot)) }
                summaries.append(summary)
            }
            return try .json(summaries)
        }

        /// `size=1` adds `SizeRw`, where the engine can tell it. `SizeRootFs` is not reported:
        /// the image's unpacked size here is a disk image's, not comparable with dockerd's.
        func inspect(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            var inspect = ContainerViewMapper.inspect(container, context: try await context())
            if try request.bool("size") { inspect.SizeRw = await engine.writableSize(container.snapshot) }
            return try .json(inspect)
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
                let incarnation = try await engine.create(plan, requester: request.peer?.requester)
                await identities.commit(reservation, incarnation: incarnation, extras: plan.extras)
                await report("create", engineID: reservation.engineID, change: .created)
                return try .json(DockerContainerCreateResponse(Id: reservation.dockerID, Warnings: plan.warnings), status: .created)
            } catch {
                await identities.release(reservation)
                throw error
            }
        }

        /// Reports what this service just did to a container, as the engine has it now.
        func report(_ action: String, engineID: String, change: DockerEventBus.ContainerChange, extra: [String: String] = [:]) async {
            guard let events, let snapshot = try? await engine.get(engineID) else { return }
            let container = await identities.resolve(snapshot)
            await events.container(action, container, change: change, extra: extra)
        }

        /// Reports what this service just did to `container`, as it was.
        func report(_ action: String, _ container: DockerContainer, change: DockerEventBus.ContainerChange = .none, extra: [String: String] = [:]) async {
            await events?.container(action, container, change: change, extra: extra)
        }

        /// The exit a stop left, from the engine, then the stop itself.
        func reportStopped(_ container: DockerContainer) async {
            guard events != nil else { return }
            let exitCode = (try? await engine.get(container.engineID))?.flatMap(\.exitCode)
            await report("die", container, change: .died(exitCode: exitCode))
            await report("stop", container)
        }

        /// The reference with `:latest` when it names no tag or digest, as dockerd reports a
        /// missing image.
        static func taggedReference(_ reference: String) -> String {
            let last = reference.split(separator: "/").last ?? Substring(reference)
            return last.contains(":") || last.contains("@") ? reference : reference + ":latest"
        }

        func start(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            if ContainerViewMapper.isRunning(container.snapshot) {
                return .empty(.notModified)
            }
            return try await start(container, requester: request.peer?.requester) == .started ? .empty() : .empty(.notModified)
        }

        /// Starts `container` with the attaches waiting for it. A container made with
        /// `--rm` that fails to start is removed, as dockerd removes it: `docker run --rm`
        /// waits for that removal before it reports the failure.
        func start(_ container: DockerContainer, requester: String?) async throws -> DockerContainerProcesses.StartOutcome {
            do {
                return try await streams.processes.start(container, requester: requester)
            } catch {
                if container.extras?.autoRemove == true {
                    try? await engine.delete(container.snapshot, force: true)
                    await removed(container, failure: DockerContainerProcesses.message(error))
                }
                throw error
            }
        }

        /// What follows a deletion: waits on it answer, attaches waiting for it go, and so do
        /// its execs that are not running.
        func removed(_ container: DockerContainer, failure: String? = nil) async {
            let engineID = container.engineID
            await report("destroy", container, change: .removed)
            await identities.forget(engineID: engineID)
            await streams.waits.removed(engineID, failure: failure)
            await streams.attaches.release(engineID: engineID)
            await streams.execs.release(engineID: engineID)
            await streams.copies.discard(engineID)
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
            let signal = request.query("signal").flatMap { $0.isEmpty ? nil : $0 }
            await report("kill", container, extra: ["signal": DockerSignals.number(signal ?? container.snapshot.configuration.stopSignal ?? "TERM")])
            try await engine.stop(container.snapshot, timeout: try stopTimeout(request), signal: signal)
            await reportStopped(container)
            return .empty()
        }

        func kill(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            guard ContainerViewMapper.isRunning(container.snapshot) else {
                throw DockerAPIError.conflict("cannot kill container: \(reference): container \(container.dockerID) is not running")
            }
            let signal = request.query("signal").flatMap { $0.isEmpty ? nil : $0 } ?? "KILL"
            try await engine.kill(container.snapshot, signal: signal)
            // The exit, if the signal ends it, is the engine's to report.
            await report("kill", container, extra: ["signal": DockerSignals.number(signal)])
            return .empty()
        }

        func restart(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, _) = try await find(reference)
            let timeout = try stopTimeout(request)
            do {
                if ContainerViewMapper.isRunning(container.snapshot) {
                    let signal = request.query("signal").flatMap { $0.isEmpty ? nil : $0 }
                    await report("kill", container, extra: ["signal": DockerSignals.number(signal ?? container.snapshot.configuration.stopSignal ?? "TERM")])
                    try await engine.stop(container.snapshot, timeout: timeout, signal: signal)
                    await reportStopped(container)
                }
                // The engine's snapshot after the stop, so that the start acts on the stopped
                // container rather than the running one seen before it.
                let stopped = try await containers().first { $0.engineID == container.engineID }
                guard let stopped else {
                    throw DockerAPIError.notFound("No such container: \(reference)")
                }
                _ = try await start(stopped, requester: request.peer?.requester)
                await report("restart", stopped)
            } catch let error as DockerAPIError {
                throw DockerAPIError(error.status, "Cannot restart container \(reference): \(error.message)")
            } catch {
                throw DockerAPIError.internalError("Cannot restart container \(reference): \(error)")
            }
            return .empty()
        }

        /// A rename is the engine's when it can make one: the name label is then what every
        /// client reads, this service's store only a cache of it, and the engine says the
        /// rename. An older engine cannot, and the name lives in the store, as it used to.
        func rename(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
            let (container, all) = try await find(reference)
            let name = try await identities.checkRename(container, to: request.query("name") ?? "", among: all)
            if await engine.supportsRename() {
                do {
                    try await engine.rename(container.snapshot, to: name)
                } catch let error as DockerAPIError where error.status == .conflict {
                    throw DockerAPIError.conflict("Error when allocating new name: \(error.message)")
                }
                await identities.renamedInEngine(container, to: name)
            } else {
                try await identities.rename(container, to: name, among: all)
            }
            if let events {
                let renamed = await identities.resolve(try await engine.get(container.engineID) ?? container.snapshot)
                await events.container("rename", renamed, change: .none, extra: ["oldName": "/" + container.name])
            }
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
            if ContainerViewMapper.isRunning(container.snapshot) {
                // A forced removal kills it, as dockerd does: SIGKILL's exit status.
                await report("kill", container, extra: ["signal": DockerSignals.number("KILL")])
                await report("die", container, change: .died(exitCode: 137))
            }
            try await engine.delete(container.snapshot, force: force)
            await removed(container)
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
            var reclaimed: Int64 = 0
            for container in try await containers() where !ContainerViewMapper.isRunning(container.snapshot) {
                let labels = container.snapshot.configuration.labels
                guard (filters["label"] ?? []).allSatisfy({ Self.labelMatches($0, labels) }),
                    !(filters["label!"] ?? []).contains(where: { Self.labelMatches($0, labels) })
                else { continue }
                // As dockerd: what each removed container wrote, measured before it goes; one
                // the engine cannot measure adds nothing.
                let size = await engine.writableSize(container.snapshot) ?? 0
                do {
                    try await engine.delete(container.snapshot, force: false)
                } catch {
                    // dockerd skips a container it cannot remove and goes on with the rest.
                    continue
                }
                await removed(container)
                deleted.append(container.dockerID)
                reclaimed += size
            }
            return try .json(DockerContainerPruneResponse(ContainersDeleted: deleted.isEmpty ? nil : deleted, SpaceReclaimed: reclaimed))
        }

        static func labelMatches(_ condition: String, _ labels: [String: String]) -> Bool {
            let parts = condition.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let value = labels[String(parts[0])] else { return false }
            return parts.count == 1 || value == parts[1]
        }
    }
}
