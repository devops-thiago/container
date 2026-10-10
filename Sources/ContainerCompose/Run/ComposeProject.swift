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

/// A compose project on the engine, and what `up`, `down` and the commands between them
/// do to it.
///
/// `up` works from a plan, which comes from the compose files. Everything else works from
/// the labels on the project's containers, so a project can be listed, stopped, started
/// in order and taken down without its files.
public struct ComposeProject: Sendable {
    public let name: String
    let engine: any ComposeEngine
    let hooks: ComposeHooks
    var readiness = Readiness()
    /// Makes a folder a container mounts when nothing is there yet.
    var makeDirectory: @Sendable (String) throws -> Void = { path in
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    var pathExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Seconds a stop waits for a container whose service sets no `stop_grace_period`,
    /// when the caller of a stop gives none either. nil leaves it to the engine.
    public var defaultStopTimeout: Int?

    public init(name: String, engine: any ComposeEngine = LiveComposeEngine(), hooks: ComposeHooks = ComposeHooks()) {
        self.name = name
        self.engine = engine
        self.hooks = hooks
    }

    public struct UpOptions: Sendable {
        /// Build images even when they exist.
        public var build = false
        /// A pull policy for every service, in place of each one's own.
        public var pull: ComposePullPolicy?
        /// Make every container again, changed or not.
        public var forceRecreate = false
        /// Keep containers as they are even when their service changed.
        public var noRecreate = false
        /// Remove the project's containers whose service the files no longer define.
        public var removeOrphans = false
        /// After starting, wait until every service with a health check is healthy.
        public var wait = false
        /// Start the containers. Without it `up` stops once they exist.
        public var start = true

        public init() {}
    }

    // MARK: Up

    public func up(_ plan: ProjectPlan, options: UpOptions = UpOptions()) async throws {
        try Task.checkCancellation()
        // A run that was cancelled stops between items: the network or volume being made is
        // finished, and no further one is begun.
        for network in plan.networks where !(try await engine.networkExists(network.name)) {
            try Task.checkCancellation()
            guard !network.external else {
                throw ComposeError(
                    "the network \(network.name) is declared external and does not exist; create it with: container network create \(network.name)")
            }
            hooks.event(ComposeEvent(.network, network.name, .creating))
            try await finishing { try await engine.createNetwork(network) }
            hooks.event(ComposeEvent(.network, network.name, .created))
        }
        for volume in plan.volumes where !(try await engine.volumeExists(volume.name)) {
            try Task.checkCancellation()
            guard !volume.external else {
                throw ComposeError(
                    "the volume \(volume.name) is declared external and does not exist; create it with: container volume create \(volume.name)")
            }
            hooks.event(ComposeEvent(.volume, volume.name, .creating))
            try await finishing { try await engine.createVolume(volume) }
            hooks.event(ComposeEvent(.volume, volume.name, .created))
        }

        let digests = try await prepareImages(plan, options: options)
        try await createContainers(plan, options: options, images: digests)
        try await handleOrphans(plan, remove: options.removeOrphans)
        guard options.start else { return }
        try await startInOrder(plan)
        if options.wait {
            for service in plan.services {
                guard let check = service.healthcheck else { continue }
                try await waitUntilHealthy(check, service: service.service, container: service.containerName)
            }
        }
    }

    /// Build what has to be built and fetch what is to be fetched afresh. Returns the
    /// digest each planned image has afterwards, for the images that are here; one that is
    /// not is fetched when its container is made.
    private func prepareImages(_ plan: ProjectPlan, options: UpOptions) async throws -> [String: String] {
        var built: [BuildPlan] = []
        var digests: [String: String] = [:]
        var seen = Set<String>()
        for service in plan.services where seen.insert(service.image).inserted {
            try Task.checkCancellation()
            let policy = options.pull ?? service.pullPolicy
            if let build = service.build {
                var digest = try await engine.imageDigest(service.image)
                if options.build || policy == .build || digest == nil, !built.contains(build) {
                    try await runBuild(build, service: service.service)
                    built.append(build)
                    digest = try await engine.imageDigest(service.image)
                }
                digests[service.image] = digest
            } else if policy == .always {
                hooks.event(ComposeEvent(.image, service.image, service: service.service, .pulling))
                let progress = hooks.progress(service.service)
                digests[service.image] = try await finishing {
                    try await engine.pullImage(service.image, platform: service.platform, progress: progress)
                }
                hooks.event(ComposeEvent(.image, service.image, service: service.service, .pulled))
            } else {
                digests[service.image] = try await engine.imageDigest(service.image)
            }
        }
        return digests
    }

    private func runBuild(_ build: BuildPlan, service: String) async throws {
        guard let builder = hooks.build else {
            throw ComposeError(
                "the image of service \(service) has to be built first. Build it with: container build \(ShellWords.join(build.arguments))")
        }
        hooks.event(ComposeEvent(.image, build.tag, service: service, .building))
        try await builder(build, service)
        hooks.event(ComposeEvent(.image, build.tag, service: service, .built))
    }

    private func createContainers(_ plan: ProjectPlan, options: UpOptions, images: [String: String]) async throws {
        let existing = try await engine.containers(project: name)
        for service in plan.services {
            // A run that was cancelled stops here, between containers: what is being
            // fetched or made is finished, and nothing further is begun.
            try Task.checkCancellation()
            var current = existing.first { $0.service == service.service }
            if current == nil, let other = try await engine.container(named: service.containerName) {
                guard other.project == name, other.service == service.service else {
                    throw ComposeError(
                        "a container named \(service.containerName) exists and is not this project's \(service.service) service; remove it, or give the service another container_name"
                    )
                }
                current = other
            }

            if let current {
                // A container runs the image it was made from. When the name has come to
                // mean another image since, by a build or a fetch, the container is stale.
                let imageChanged = images[service.image].map { $0 != current.imageDigest } ?? false
                let changed = current.configHash != service.configHash || current.id != service.containerName || imageChanged
                guard options.forceRecreate || (changed && !options.noRecreate) else { continue }
                hooks.event(ComposeEvent(.container, current.id, service: service.service, .recreating))
                let timeout = current.stopTimeout ?? defaultStopTimeout
                try await finishing {
                    if current.state != .stopped {
                        try await engine.stopContainer(current.id, timeout: timeout)
                    }
                    try await engine.removeContainer(current.id)
                }
            } else {
                hooks.event(ComposeEvent(.container, service.containerName, service: service.service, .creating))
            }

            // A folder that is not there yet is made, as it is when the other tool mounts one.
            for source in service.bindSources where !pathExists(source) {
                do {
                    try makeDirectory(source)
                } catch {
                    throw ComposeError(
                        "the folder \(source), which service \(service.service) mounts, does not exist and could not be made: \(error.localizedDescription)")
                }
            }

            var arguments = service.options
            // An image fetched a moment ago is not fetched again by the create.
            let policy = options.pull ?? service.pullPolicy
            arguments = Self.settingPull(policy == .never ? "never" : nil, in: arguments)
            for port in service.ephemeralPorts {
                let free = try await engine.freeHostPort()
                arguments.append(contentsOf: ["--publish", ServiceLowering.publishSpecification(port, published: "\(free)")])
            }
            let request = ContainerRequest(
                name: service.containerName, image: service.image, options: arguments, command: service.command,
                stopSignal: service.stopSignal)
            let progress = hooks.progress(service.service)
            try await finishing { try await engine.createContainer(request, progress: progress) }
            hooks.event(ComposeEvent(.container, service.containerName, service: service.service, .created))
        }
    }

    /// Runs engine work that changes something to its end, whatever becomes of the run.
    ///
    /// The engine's calls give up when the task they are in is cancelled, and a container
    /// abandoned halfway through being made is worse than one made a moment late. So the
    /// work goes in a task of its own: a cancelled run waits for it, and stops at its
    /// next step.
    private func finishing<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await work() }.value
    }

    /// `options` with its `--pull` taken out and, when a policy is given, that one put in.
    static func settingPull(_ policy: String?, in options: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < options.count {
            if options[index] == "--pull" {
                index += 2
                continue
            }
            result.append(options[index])
            index += 1
        }
        if let policy { result.append(contentsOf: ["--pull", policy]) }
        return result
    }

    private func handleOrphans(_ plan: ProjectPlan, remove: Bool) async throws {
        let defined = Set(plan.definedServices)
        let orphans = try await engine.containers(project: name).filter { container in
            container.service.map { !defined.contains($0) } ?? true
        }
        guard !orphans.isEmpty else { return }
        guard remove else {
            hooks.warning(
                "the project has containers that no service in the compose file accounts for: \(orphans.map(\.id).sorted().joined(separator: ", ")). Remove them with --remove-orphans"
            )
            return
        }
        for orphan in orphans {
            try await stopAndRemove(orphan, timeout: nil)
        }
    }

    private func startInOrder(_ plan: ProjectPlan) async throws {
        // What has been waited for already, so that two services depending on the same
        // one do not wait twice.
        var satisfied = Set<String>()
        let dependents = Self.dependentsOnCompletion(plan.services.map { ($0.service, $0.dependencies) })
        for service in plan.services {
            try Task.checkCancellation()
            for dependency in service.dependencies {
                let key = "\(dependency.service)/\(dependency.condition.rawValue)"
                guard !satisfied.contains(key), let target = plan.service(dependency.service) else { continue }
                do {
                    try await wait(for: dependency, container: target.containerName, healthcheck: target.healthcheck)
                    satisfied.insert(key)
                } catch let error as ComposeError where !dependency.required {
                    hooks.warning("\(service.service) starts without \(dependency.service), which it does not require: \(error)")
                }
            }
            let waiting = (dependents[service.service] ?? []).compactMap { plan.service($0)?.containerName }
            if try await hasDoneItsJob(container: service.containerName, service: service.service, for: waiting) { continue }
            try await start(container: service.containerName, service: service.service)
        }
        // A cancel that landed during the last start is still a cancel: the start was
        // finished, as every step under way is, and the run does not report success.
        try Task.checkCancellation()
    }

    /// For each service that others wait on to finish, the services that wait.
    static func dependentsOnCompletion(_ services: [(service: String, dependencies: [ComposeDependency])]) -> [String: [String]] {
        var dependents: [String: [String]] = [:]
        for (service, dependencies) in services {
            for dependency in dependencies where dependency.condition == .completedSuccessfully {
                dependents[dependency.service, default: []].append(service)
            }
        }
        return dependents
    }

    /// Whether a service that others wait on to finish has finished for them already: its
    /// container ended without an error and one of the containers that waited for it is
    /// running.
    ///
    /// Such a service ran before what depends on it started, and a job that prepared a
    /// volume cannot run again while the service using that volume holds it. When
    /// everything that waited is stopped, the job runs again before any of it starts.
    private func hasDoneItsJob(container: String, service: String, for waiting: [String]) async throws -> Bool {
        guard !waiting.isEmpty, let current = try await engine.container(named: container),
            current.state == .stopped, current.exitCode == 0
        else { return false }
        for dependent in waiting where try await engine.container(named: dependent)?.state == .running {
            return true
        }
        return false
    }

    private func wait(for dependency: ComposeDependency, container: String, healthcheck: ComposeHealthcheck?) async throws {
        switch dependency.condition {
        case .started:
            break
        case .healthy:
            guard let healthcheck else {
                throw ComposeError("service \(dependency.service) has no health check to wait for")
            }
            try await waitUntilHealthy(healthcheck, service: dependency.service, container: container)
        case .completedSuccessfully:
            // One that has ended already is not waited for, only looked at.
            let ended = try await engine.container(named: container).map { $0.state == .stopped && $0.exitCode != nil } ?? false
            if !ended {
                hooks.event(ComposeEvent(.container, container, service: dependency.service, .waiting, detail: "to finish"))
            }
            let exitCode: Int32
            do {
                exitCode = try await readiness.waitUntilExited(service: dependency.service, container: container, engine: engine)
            } catch let error as ComposeError {
                hooks.event(ComposeEvent(.container, container, service: dependency.service, .failed, detail: "\(error)"))
                throw error
            }
            guard exitCode == 0 else {
                let reason = "service \(dependency.service) did not finish successfully: its container \(container) ended with exit code \(exitCode)"
                hooks.event(ComposeEvent(.container, container, service: dependency.service, .failed, detail: reason))
                throw ComposeError(reason)
            }
            hooks.event(ComposeEvent(.container, container, service: dependency.service, .completed))
        }
    }

    private func waitUntilHealthy(_ check: ComposeHealthcheck, service: String, container: String) async throws {
        hooks.event(ComposeEvent(.container, container, service: service, .waiting, detail: "to be healthy"))
        do {
            try await readiness.waitUntilHealthy(check, service: service, container: container, engine: engine)
        } catch let error as ComposeError {
            hooks.event(ComposeEvent(.container, container, service: service, .failed, detail: "\(error)"))
            throw error
        }
        hooks.event(ComposeEvent(.container, container, service: service, .healthy))
    }

    private func start(container: String, service: String) async throws {
        // One the engine is about to restart is up as far as compose is concerned, as Docker
        // counts a restarting container as running: starting it by hand would reset its
        // restart count and skip the delay.
        let state = try await engine.container(named: container)?.state
        if state == .running || state == .restarting {
            hooks.event(ComposeEvent(.container, container, service: service, .running))
            return
        }
        hooks.event(ComposeEvent(.container, container, service: service, .starting))
        do {
            try await finishing { try await engine.startContainer(container) }
        } catch {
            hooks.event(ComposeEvent(.container, container, service: service, .failed, detail: "\(error)"))
            throw error
        }
        hooks.event(ComposeEvent(.container, container, service: service, .started))
    }

    // MARK: The project as it is

    /// The project's containers, by service.
    public func containers() async throws -> [ComposeContainer] {
        try await engine.containers(project: name).sorted { ($0.service ?? "", $0.id) < ($1.service ?? "", $1.id) }
    }

    /// The project's containers in the order they start: each after the services its
    /// labels say it depends on. Containers of `services` only, when any are named.
    func containersInStartOrder(services: [String] = []) async throws -> [ComposeContainer] {
        let all = try await engine.containers(project: name)
        for service in services where !all.contains(where: { $0.service == service }) {
            throw ComposeError("the project \(name) has no container for a service named '\(service)'")
        }
        let chosen = services.isEmpty ? all : all.filter { services.contains($0.service ?? "") }
        var dependencies: [String: [String]] = [:]
        for container in chosen {
            dependencies[container.service ?? container.id] = container.dependencies.map(\.service)
        }
        // Labels written by hand can describe a circle; names are an order all the same.
        let order = (try? DependencyGraph(dependencies: dependencies).startOrder()) ?? dependencies.keys.sorted()
        return order.flatMap { service in chosen.filter { ($0.service ?? $0.id) == service }.sorted { $0.id < $1.id } }
    }

    // MARK: Start, stop, restart

    /// Start the project's stopped containers in order, waiting for what each depends on
    /// as its labels describe.
    public func start(services: [String] = []) async throws {
        let ordered = try await containersInStartOrder(services: services)
        let everyone = try await engine.containers(project: name)
        var satisfied = Set<String>()
        let dependents = Self.dependentsOnCompletion(everyone.map { ($0.service ?? $0.id, $0.dependencies) })
        for container in ordered {
            try Task.checkCancellation()
            let service = container.service ?? container.id
            for dependency in container.dependencies {
                let key = "\(dependency.service)/\(dependency.condition.rawValue)"
                guard !satisfied.contains(key), let target = everyone.first(where: { $0.service == dependency.service }),
                    services.isEmpty || services.contains(dependency.service)
                else { continue }
                try await wait(for: dependency, container: target.id, healthcheck: target.healthcheck)
                satisfied.insert(key)
            }
            let waiting = everyone.filter { (dependents[service] ?? []).contains($0.service ?? "") }.map(\.id)
            if try await hasDoneItsJob(container: container.id, service: service, for: waiting) { continue }
            try await start(container: container.id, service: service)
        }
    }

    /// Stop the project's running containers, the ones others depend on last.
    public func stop(services: [String] = [], timeout: Int? = nil) async throws {
        for container in try await containersInStartOrder(services: services).reversed() where container.state != .stopped {
            try await stop(container, timeout: timeout)
        }
    }

    public func restart(services: [String] = [], timeout: Int? = nil) async throws {
        try await stop(services: services, timeout: timeout)
        try await start(services: services)
    }

    private func stop(_ container: ComposeContainer, timeout: Int?) async throws {
        hooks.event(ComposeEvent(.container, container.id, service: container.service, .stopping))
        try await engine.stopContainer(container.id, timeout: timeout ?? container.stopTimeout ?? defaultStopTimeout)
        hooks.event(ComposeEvent(.container, container.id, service: container.service, .stopped))
    }

    private func stopAndRemove(_ container: ComposeContainer, timeout: Int?) async throws {
        if container.state != .stopped {
            try await stop(container, timeout: timeout)
        }
        hooks.event(ComposeEvent(.container, container.id, service: container.service, .removing))
        try await engine.removeContainer(container.id)
        hooks.event(ComposeEvent(.container, container.id, service: container.service, .removed))
    }

    // MARK: Down

    /// Stop and remove the project's containers and the networks compose made for it.
    /// Volumes hold data and stay, unless `removeVolumes` says otherwise; what is
    /// declared external was never the project's and stays either way.
    public func down(removeVolumes: Bool = false, timeout: Int? = nil) async throws {
        let ordered = try await containersInStartOrder().reversed()
        for container in ordered where container.state != .stopped {
            try await stop(container, timeout: timeout)
        }
        for container in ordered {
            hooks.event(ComposeEvent(.container, container.id, service: container.service, .removing))
            try await engine.removeContainer(container.id)
            hooks.event(ComposeEvent(.container, container.id, service: container.service, .removed))
        }
        for network in try await engine.networks(project: name).sorted() {
            hooks.event(ComposeEvent(.network, network, .removing))
            try await engine.removeNetwork(network)
            hooks.event(ComposeEvent(.network, network, .removed))
        }
        guard removeVolumes else { return }
        for volume in try await engine.volumes(project: name).sorted() {
            hooks.event(ComposeEvent(.volume, volume, .removing))
            try await engine.removeVolume(volume)
            hooks.event(ComposeEvent(.volume, volume, .removed))
        }
    }

    // MARK: Images

    /// Fetch the image of every planned service that runs one from a registry.
    public func pull(_ plan: ProjectPlan) async throws {
        var fetched = Set<String>()
        for service in plan.services where service.build == nil && fetched.insert(service.image).inserted {
            hooks.event(ComposeEvent(.image, service.image, service: service.service, .pulling))
            _ = try await engine.pullImage(service.image, platform: service.platform, progress: hooks.progress(service.service))
            hooks.event(ComposeEvent(.image, service.image, service: service.service, .pulled))
        }
    }

    /// Build the image of every planned service that has a build.
    public func build(_ plan: ProjectPlan) async throws {
        var built: [BuildPlan] = []
        for service in plan.services {
            guard let build = service.build, !built.contains(build) else { continue }
            try await runBuild(build, service: service.service)
            built.append(build)
        }
    }
}
