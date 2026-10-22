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
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging
import Synchronization
import XPC

@testable import ContainerAPIService

/// Reads a stream of container events for the whole of a test, so the test can look at what
/// arrived so far without ending the stream.
final class EventCollector: Sendable {
    private final class Received: Sendable {
        let events = Mutex<[ContainerEvent]>([])
        let ending = Mutex<(ended: Bool, error: String?)>((false, nil))
    }

    private let received = Received()
    private let taken = Mutex(0)
    private let task: Task<Void, Never>

    init(_ stream: AsyncThrowingStream<ContainerEvent, any Error>) {
        let received = self.received
        task = Task {
            do {
                for try await event in stream { received.events.withLock { $0.append(event) } }
                received.ending.withLock { $0 = (true, nil) }
            } catch {
                received.ending.withLock { $0 = (true, String(describing: error)) }
            }
        }
    }

    /// Reads the read end of a hub subscription.
    convenience init(_ subscription: ContainerEventHub.Subscription) {
        self.init(ContainerEventLines.events(from: subscription.handle.fileDescriptor))
    }

    deinit { task.cancel() }

    var all: [ContainerEvent] { received.events.withLock { $0 } }
    var ended: Bool { received.ending.withLock { $0.ended } }
    var endError: String? { received.ending.withLock { $0.error } }

    /// The next `count` events, or what arrived of them within `within`.
    func take(_ count: Int, within: Duration = .seconds(5)) async -> [ContainerEvent] {
        let deadline = ContinuousClock.now.advanced(by: within)
        while received.events.withLock({ $0.count }) - taken.withLock({ $0 }) < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return next()
    }

    /// Waits until `count` events have arrived in all, for up to `within`.
    func waitFor(_ count: Int, within: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while received.events.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return received.events.withLock { $0.count } >= count
    }

    /// What arrives within a short while.
    func settle(_ within: Duration = .milliseconds(200)) async -> [ContainerEvent] {
        try? await Task.sleep(for: within)
        return next()
    }

    /// Waits for the stream to end, for up to `within`.
    func waitForEnd(within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: within)
        while !ended, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ended
    }

    private func next() -> [ContainerEvent] {
        let all = received.events.withLock { $0 }
        return taken.withLock { taken in
            defer { taken = all.count }
            return Array(all[min(taken, all.count)...])
        }
    }

    static func actions(_ events: [ContainerEvent]) -> [String] {
        events.map(\.action.rawValue)
    }
}

/// A runtime helper that runs nothing: an XPC listener answering the routes the containers
/// service sends a runtime, whose process ends when the test says, or as `Behavior` says.
final class FakeRuntime: Sendable {
    struct Behavior: Sendable {
        /// The process exits with this as soon as it starts.
        var exitOnStart: Int32? = nil
        /// A stop ends the process with this; nil leaves its exit unanswered.
        var exitOnStop: Int32? = 143
        /// SIGKILL ends the process with this.
        var exitOnKill: Int32? = 137
        /// Health updates handed out in order to the service's health watch.
        var health: [HealthUpdate] = []
        /// Copies in of a source with one of these names fail.
        var copyInFailures: Set<String> = []
        /// Starts of processes with these IDs are not answered until `releaseHeldStarts()`, as
        /// a guest that is out of memory does not answer an exec.
        var holdStarts: Set<String> = []
    }

    private struct State {
        var exit: ExitStatus?
        var waiters: [CheckedContinuation<ExitStatus?, Never>] = []
        var heldStarts: [CheckedContinuation<Void, Never>] = []
        var released = false
        var healthWaiters: [CheckedContinuation<HealthUpdate?, Never>] = []
        var health: [HealthUpdate]
        var started = 0
        var signals: [String] = []
        var closed = false
        /// Copies in and starts, in the order they came.
        var calls: [String] = []
        /// What the runtime says of the OOM killer in its state: nil, as a runtime that does
        /// not say, until the test sets it.
        var oomKilled: Bool?
    }

    private final class Shared: Sendable {
        let state: Mutex<State>
        init(_ state: State) { self.state = Mutex(state) }
    }

    private nonisolated(unsafe) let listener: xpc_connection_t
    private let listening: Task<Void, Never>
    private let shared: Shared
    let behavior: Behavior

    init(_ behavior: Behavior = Behavior()) {
        self.behavior = behavior
        let shared = Shared(State(health: behavior.health))
        self.shared = shared
        let listener = xpc_connection_create(nil, nil)
        self.listener = listener
        let routes: [String: XPCServer.RouteHandler] = [
            RuntimeRoutes.bootstrap.rawValue: XPCServer.route { $0.reply() },
            RuntimeRoutes.start.rawValue: XPCServer.route { message in
                let process = message.string(key: RuntimeKeys.id.rawValue) ?? ""
                shared.state.withLock {
                    $0.started += 1
                    $0.calls.append(behavior.holdStarts.contains(process) ? "start \(process) held" : "start")
                }
                if behavior.holdStarts.contains(process) {
                    await withCheckedContinuation { continuation in
                        let now = shared.state.withLock { state in
                            if state.released || state.closed { return true }
                            state.heldStarts.append(continuation)
                            return false
                        }
                        if now { continuation.resume() }
                    }
                    return message.reply()
                }
                if let code = behavior.exitOnStart { Self.exit(shared, code) }
                return message.reply()
            },
            RuntimeRoutes.createProcess.rawValue: XPCServer.route { message in
                let process = message.string(key: RuntimeKeys.id.rawValue) ?? ""
                shared.state.withLock { $0.calls.append("createProcess \(process)") }
                return message.reply()
            },
            RuntimeRoutes.state.rawValue: XPCServer.route { message in
                let reply = message.reply()
                reply.set(
                    key: RuntimeKeys.snapshot.rawValue,
                    value: try JSONEncoder().encode(
                        SandboxSnapshot(
                            status: .running, networks: [], containers: [],
                            oomKilled: shared.state.withLock { $0.oomKilled })))
                return reply
            },
            RuntimeRoutes.wait.rawValue: XPCServer.route { message in
                let status = await withCheckedContinuation { continuation in
                    let now = shared.state.withLock { state -> ExitStatus?? in
                        if let exit = state.exit { return .some(exit) }
                        if state.closed { return .some(nil) }
                        state.waiters.append(continuation)
                        return nil
                    }
                    if let now { continuation.resume(returning: now) }
                }
                guard let status else { throw ContainerizationError(.interrupted, message: "fake runtime closed") }
                let reply = message.reply()
                reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(status.exitCode))
                reply.set(key: RuntimeKeys.exitedAt.rawValue, value: status.exitedAt)
                return reply
            },
            RuntimeRoutes.stop.rawValue: XPCServer.route { message in
                if let code = behavior.exitOnStop { Self.exit(shared, code) }
                return message.reply()
            },
            RuntimeRoutes.kill.rawValue: XPCServer.route { message in
                let signal = message.string(key: RuntimeKeys.signal.rawValue) ?? ""
                shared.state.withLock { $0.signals.append(signal) }
                if ["SIGKILL", "KILL", "9"].contains(signal.uppercased()), let code = behavior.exitOnKill { Self.exit(shared, code) }
                return message.reply()
            },
            RuntimeRoutes.shutdown.rawValue: XPCServer.route { $0.reply() },
            RuntimeRoutes.copyIn.rawValue: XPCServer.route { message in
                let source = URL(fileURLWithPath: message.string(key: RuntimeKeys.sourcePath.rawValue) ?? "")
                let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) ?? ""
                let content = (try? String(contentsOf: source, encoding: .utf8)) ?? "?"
                shared.state.withLock { $0.calls.append("copyIn \(source.lastPathComponent)=\(content) \(destination)") }
                if behavior.copyInFailures.contains(source.lastPathComponent) {
                    throw ContainerizationError(.internalError, message: "disk full")
                }
                return message.reply()
            },
            RuntimeRoutes.waitHealth.rawValue: XPCServer.route { message in
                let after = message.uint64(key: RuntimeKeys.healthGeneration.rawValue)
                let update = await withCheckedContinuation { continuation in
                    let now = shared.state.withLock { state -> HealthUpdate?? in
                        if let next = state.health.first(where: { $0.generation > after }) { return .some(next) }
                        if state.closed { return .some(nil) }
                        state.healthWaiters.append(continuation)
                        return nil
                    }
                    if let now { continuation.resume(returning: now) }
                }
                let reply = message.reply()
                reply.set(
                    key: RuntimeKeys.health.rawValue,
                    value: try JSONEncoder().encode(update ?? HealthUpdate(health: nil, generation: after + 1, finished: true)))
                return reply
            },
        ]
        let server = XPCServer(connection: listener, routes: routes, log: Logger(label: "FakeRuntime"))
        listening = Task { try? await server.listen() }
    }

    /// A client of this runtime, as the service makes one for a container.
    func client(id: String, runtime: String) -> RuntimeClient {
        RuntimeClient.create(id: id, runtime: runtime, endpoint: xpc_endpoint_create(listener))
    }

    /// Answers every start held by `Behavior.holdStarts`, and those still to come.
    func releaseHeldStarts() {
        let held = shared.state.withLock { state in
            state.released = true
            defer { state.heldStarts = [] }
            return state.heldStarts
        }
        for start in held { start.resume() }
    }

    /// The process ends with `code`.
    func exit(_ code: Int32) {
        Self.exit(shared, code)
    }

    /// The runtime's state says whether the OOM killer killed a process in the container this
    /// run, as the Linux runtime reads it from the cgroup's memory events.
    func reportOOMKilled(_ killed: Bool) {
        shared.state.withLock { $0.oomKilled = killed }
    }

    var starts: Int { shared.state.withLock { $0.started } }
    var calls: [String] { shared.state.withLock { $0.calls } }
    var signals: [String] { shared.state.withLock { $0.signals } }

    private static func exit(_ shared: Shared, _ code: Int32) {
        let waiters = shared.state.withLock { state -> [CheckedContinuation<ExitStatus?, Never>] in
            guard state.exit == nil else { return [] }
            state.exit = ExitStatus(exitCode: code, exitedAt: Date())
            defer { state.waiters = [] }
            return state.waiters
        }
        let status = shared.state.withLock { $0.exit }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// Answer every wait still open, and stop listening.
    func close() {
        let (waiters, healthWaiters, heldStarts) = shared.state.withLock { state in
            state.closed = true
            defer {
                state.waiters = []
                state.healthWaiters = []
                state.heldStarts = []
            }
            return (state.waiters, state.healthWaiters, state.heldStarts)
        }
        for start in heldStarts { start.resume() }
        for waiter in waiters { waiter.resume(returning: nil) }
        for waiter in healthWaiters { waiter.resume(returning: nil) }
        xpc_connection_cancel(listener)
        listening.cancel()
    }
}

/// A containers service over a temporary root, whose runtime helpers are `FakeRuntime`s: one
/// per start, made by `next`.
final class EventServiceFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("container-events-\(UUID().uuidString)")
    let log = Logger(label: "ContainerEventTests")
    let runtimeName = "container-runtime-linux"
    let hub: ContainerEventHub
    private let runtimes = Mutex<[FakeRuntime]>([])
    private let behaviors = Mutex<[FakeRuntime.Behavior]>([])
    /// Makes the next start fail at its launch, as a helper that cannot be registered does.
    let failNextLaunch = Mutex(false)
    let deregistered = Mutex<[String]>([])

    init(limits: ContainerEventHub.Limits = .init()) {
        hub = ContainerEventHub(processNonce: UUID().uuidString, limits: limits, log: Logger(label: "ContainerEventTests"))
    }

    var containers: URL { root.appendingPathComponent("containers") }

    /// The behaviour of the runtimes started from now on, in order; the last one repeats.
    func behave(_ list: FakeRuntime.Behavior...) {
        behaviors.withLock { $0 = list }
    }

    var lastRuntime: FakeRuntime? { runtimes.withLock { $0.last } }
    var runtimeCount: Int { runtimes.withLock { $0.count } }

    func service(
        restartDelay: @escaping @Sendable (Duration) async throws -> Void = { _ in }, labelPolicy: ContainerLabelPolicy = .fixed
    ) throws -> ContainersService {
        let loader = try loader()
        let hooks = self.hooks()
        return try ContainersService(
            appRoot: root, pluginLoader: loader, containerSystemConfig: ContainerSystemConfig(), log: log, restartDelay: restartDelay,
            events: hub, labelPolicy: labelPolicy, hooks: hooks)
    }

    /// A plugin loader that finds the fixture's runtime plugin, which is never executed.
    func loader() throws -> PluginLoader {
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        let plugins = root.appendingPathComponent("plugins")
        let plugin = plugins.appendingPathComponent(runtimeName)
        let bin = plugin.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent(runtimeName))
        try Data(
            """
            abstract = "Events fixture; never executed"
            [servicesConfig]
            loadAtBoot = false
            runAtLoad = false
            defaultArguments = []
            [[servicesConfig.services]]
            type = "runtime"
            """.utf8
        ).write(to: plugin.appendingPathComponent("config.toml"))
        return try PluginLoader(
            appRoot: root, installRoot: root, logRoot: nil,
            pluginDirectories: [plugins], pluginFactories: [DefaultPluginFactory(logger: log)])
    }

    private func hooks() -> ContainersService.Hooks {
        ContainersService.Hooks(
            launchRuntime: { [self] _, configuration, path in
                if failNextLaunch.withLock({ fail in
                    defer { fail = false }
                    return fail
                }) {
                    throw ContainerizationError(.internalError, message: "the helper could not be registered")
                }
                // What the real helper writes at its first start.
                let bundle = ContainerResource.Bundle(path: path)
                if (try? bundle.configuration) == nil {
                    try bundle.set(configuration: configuration)
                }
                if (try? bundle.load(filename: "options.json") as ContainerCreateOptions) == nil {
                    try bundle.write(filename: "options.json", value: ContainerCreateOptions(autoRemove: false))
                }
                let behavior = behaviors.withLock { list in
                    list.count > 1 ? list.removeFirst() : (list.first ?? FakeRuntime.Behavior())
                }
                let runtime = FakeRuntime(behavior)
                runtimes.withLock { $0.append(runtime) }
                return runtime.client(id: configuration.id, runtime: configuration.runtimeHandler)
            },
            deregister: { [self] label in deregistered.withLock { $0.append(label) } },
            initFilesystem: { _, _ in
                .block(format: "ext4", source: "/dev/null", destination: "/", options: ["ro"])
            })
    }

    func configuration(
        id: String = "events-\(UUID().uuidString.prefix(8).lowercased())", labels: [String: String] = [:],
        restartPolicy: ContainerConfiguration.RestartPolicy? = nil, healthCheck: HealthCheckConfiguration? = nil
    ) -> ContainerConfiguration {
        var configuration = ContainerConfiguration(
            id: id,
            image: .init(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        configuration.labels = labels
        configuration.restartPolicy = restartPolicy
        configuration.healthCheck = healthCheck
        return configuration
    }

    /// Makes a container through the service's own create.
    @discardableResult
    func create(_ service: ContainersService, _ configuration: ContainerConfiguration) async throws -> String {
        let kernel = Kernel(path: URL(fileURLWithPath: "/dev/null"), platform: .linuxArm)
        let rootfs = Filesystem.block(format: "ext4", source: "/dev/null", destination: "/", options: [])
        return try await service.create(
            configuration: configuration, kernel: kernel, options: ContainerCreateOptions(autoRemove: false, rootFsOverride: rootfs))
    }

    /// Starts a container as `container start` does: bootstrap, then its init process.
    func start(_ service: ContainersService, _ id: String) async throws {
        try await service.bootstrap(id: id, stdio: [nil, nil, nil], dynamicEnv: [:])
        try await service.startProcess(id: id, processID: id)
    }

    func cleanup() {
        for runtime in runtimes.withLock({ $0 }) { runtime.close() }
        try? FileManager.default.removeItem(at: root)
    }
}
