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

/// One event, as `GET /events` streams it.
public struct DockerEvent: Sendable, Equatable {
    public var type: String
    public var action: String
    public var actorID: String
    public var attributes: [String: String]
    public var time: Date

    public init(type: String, action: String, actorID: String, attributes: [String: String], time: Date) {
        self.type = type
        self.action = action
        self.actorID = actorID
        self.attributes = attributes
        self.time = time
    }

    /// The message on the wire. Below API 1.52, which is all this service speaks, dockerd adds
    /// the fields it deprecated in 1.22 to container and image events: the CLI read them until
    /// 25.0.
    struct Message: Encodable {
        struct ActorBody: Encodable {
            let ID: String
            let Attributes: [String: String]
        }

        let status: String?
        let id: String?
        let from: String?
        let `Type`: String
        let Action: String
        let Actor: ActorBody
        let scope: String
        let time: Int64
        let timeNano: Int64
    }

    var message: Message {
        let nanos = Int64((time.timeIntervalSince1970 * 1_000_000_000).rounded())
        let legacy = type == "container" || type == "image"
        return Message(
            status: legacy ? action : nil, id: legacy ? actorID : nil, from: type == "container" ? attributes["image"] : nil,
            Type: type, Action: action, Actor: .init(ID: actorID, Attributes: attributes), scope: "local",
            time: nanos / 1_000_000_000, timeNano: nanos)
    }
}

/// How much the event bus holds.
public struct DockerEventLimits: Sendable {
    /// Clients streaming `/events` at once.
    public var maxSubscribers: Int
    /// Events held for a subscriber that has not taken them. One that falls this far behind is
    /// dropped, rather than held for without bound.
    public var bufferedEvents: Int
    /// How often the engine's containers are read while anyone is subscribed.
    public var pollInterval: Duration

    public init(maxSubscribers: Int = 64, bufferedEvents: Int = 1024, pollInterval: Duration = .seconds(1)) {
        self.maxSubscribers = maxSubscribers
        self.bufferedEvents = bufferedEvents
        self.pollInterval = pollInterval
    }
}

/// The events this service reports, to the clients streaming `/events`.
///
/// Two sources, as stage A's review decided: what this service does itself is reported as it
/// does it (a create, a start, a kill, a pull, a volume or network made), and everything else
/// is found by reading the engine's containers once a second while anyone is subscribed and
/// comparing them with the last reading: a container that appeared, started, died, changed
/// health or went. A change this service reported itself is not reported again by the
/// reading that follows. Nothing is kept for a client that was not subscribed: there is no
/// history.
///
/// Each subscriber has its own bounded buffer. One that falls behind by more than it holds is
/// dropped with a warning, and its stream ends.
public actor DockerEventBus {
    public typealias ContainerSource = @Sendable () async throws -> [DockerContainer]

    /// A container as the last reading saw it, or as this service last left it.
    struct Observed: Equatable {
        enum State: Equatable {
            case created
            case running
            case stopped
            /// Deleted by this service; kept until a reading begun after it no longer lists it.
            case removed
        }

        var state: State
        var startedDate: Date?
        var health: String?
        var dockerID: String
        var attributes: [String: String]
    }

    private struct Subscriber {
        let continuation: AsyncStream<DockerEvent>.Continuation
        let filter: DockerEventFilter
    }

    private let limits: DockerEventLimits
    private let source: ContainerSource?
    private let log: Logger
    private let now: @Sendable () -> Date
    private var subscribers: [UInt64: Subscriber] = [:]
    private var nextID: UInt64 = 0
    private var poller: Task<Void, Never>?
    /// The last reading, by engine ID; nil until the first reading after a subscribe.
    private var baseline: [String: Observed]?
    /// Counts this service's own changes, so a reading taken before one does not undo it.
    private var sequence: UInt64 = 0
    private var touched: [String: UInt64] = [:]
    /// Containers whose exit has been reported for their current run, by engine ID, so that
    /// the exit reported by a stop and by the process's own waiter is said once. Kept while
    /// anyone is subscribed; bounded by the containers there are.
    private var exitReported: Set<String> = []
    /// Containers whose destroy has been reported, newest last, so that an exit heard after
    /// it (a forced removal's process waiter, late) is not reported. Bounded.
    private var destroyed: [String] = []
    private static let destroyedKept = 1024

    /// - Parameter source: the containers to read while anyone is subscribed, as the container
    ///   routes see them; nil reports only what this service does.
    public init(
        limits: DockerEventLimits = .init(), log: Logger = Logger(label: "DockerAPIService"), now: @escaping @Sendable () -> Date = { Date() },
        source: ContainerSource? = nil
    ) {
        self.limits = limits
        self.source = source
        self.log = log
        self.now = now
    }

    // MARK: Subscribers

    /// A stream of the events `filter` takes, from now on, until `cancel` or the bus drops it.
    public func subscribe(_ filter: DockerEventFilter) throws(DockerAPIError) -> (id: UInt64, events: AsyncStream<DockerEvent>) {
        guard subscribers.count < limits.maxSubscribers else {
            throw DockerAPIError(.serviceUnavailable, "too many clients are streaming events: \(limits.maxSubscribers) at once")
        }
        nextID += 1
        let id = nextID
        let (stream, continuation) = AsyncStream.makeStream(of: DockerEvent.self, bufferingPolicy: .bufferingOldest(limits.bufferedEvents))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(id) }
        }
        subscribers[id] = Subscriber(continuation: continuation, filter: filter)
        if subscribers.count == 1 { startPolling() }
        return (id, stream)
    }

    /// Ends a subscriber's stream. Once none is left, the engine is no longer read.
    public func cancel(_ id: UInt64) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.finish()
        if subscribers.isEmpty { stopPolling() }
    }

    public var subscriberCount: Int { subscribers.count }

    /// Ends every stream: the agent is stopping.
    public func shutdown() {
        for id in Array(subscribers.keys) { cancel(id) }
    }

    /// Sends `event` to every subscriber whose filter takes it. One whose buffer is full is
    /// dropped rather than buffered for without bound.
    public func publish(_ event: DockerEvent) {
        for (id, subscriber) in subscribers where subscriber.filter.includes(event) {
            if case .dropped = subscriber.continuation.yield(event) {
                log.warning("dropped an events client that fell behind", metadata: ["buffered": "\(limits.bufferedEvents)"])
                cancel(id)
            }
        }
    }

    public func publish(type: String, action: String, actorID: String, attributes: [String: String]) {
        guard !subscribers.isEmpty else { return }
        publish(DockerEvent(type: type, action: action, actorID: actorID, attributes: attributes, time: now()))
    }

    // MARK: This service's own container changes

    /// What a change this service made leaves the container as.
    public enum ContainerChange: Sendable {
        case created
        case started
        /// Its process exited, with this status when it is known.
        case died(exitCode: Int32?)
        case removed
        /// Nothing about its state: a kill or a stop request, a rename.
        case none
    }

    /// Reports `action` for `container`, which this service just did, and remembers what it
    /// left the container as, so the next reading does not report it again. A `die` already
    /// reported for this run is not reported twice.
    public func container(_ action: String, _ container: DockerContainer, change: ContainerChange, extra: [String: String] = [:]) {
        guard !subscribers.isEmpty else { return }
        let engineID = container.engineID
        var attributes = Self.attributes(container)
        attributes.merge(extra) { _, new in new }
        switch change {
        case .died(let code):
            guard !destroyed.contains(engineID), exitReported.insert(engineID).inserted else { return }
            if let code { attributes["exitCode"] = "\(code)" }
        case .started, .created:
            exitReported.remove(engineID)
            destroyed.removeAll { $0 == engineID }
        case .removed:
            exitReported.remove(engineID)
            markDestroyed(engineID)
        case .none:
            break
        }
        publish(type: "container", action: action, actorID: container.dockerID, attributes: attributes)
        guard baseline != nil else { return }
        sequence += 1
        touched[engineID] = sequence
        var observed = baseline?[engineID] ?? Observed(state: .created, dockerID: container.dockerID, attributes: Self.attributes(container))
        observed.dockerID = container.dockerID
        observed.attributes = Self.attributes(container)
        switch change {
        case .created: observed.state = .created
        case .started: observed.state = .running
        case .died: observed.state = .stopped
        case .removed: observed.state = .removed
        case .none: break
        }
        baseline?[engineID] = observed
    }

    private func markDestroyed(_ engineID: String) {
        destroyed.removeAll { $0 == engineID }
        destroyed.append(engineID)
        if destroyed.count > Self.destroyedKept { destroyed.removeFirst(destroyed.count - Self.destroyedKept) }
    }

    /// The attributes dockerd gives a container's events: its labels, its image and its name.
    static func attributes(_ container: DockerContainer) -> [String: String] {
        var attributes = ContainerViewMapper.labels(container)
        attributes["image"] = ContainerViewMapper.image(container)
        attributes["name"] = container.name
        return attributes
    }

    // MARK: Reading the engine

    private func startPolling() {
        guard let source, poller == nil else { return }
        let interval = limits.pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(source)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPolling() {
        poller?.cancel()
        poller = nil
        baseline = nil
        touched = [:]
        exitReported = []
        destroyed = []
    }

    /// Reads the containers once and reports what changed since the last reading. The first
    /// reading after a subscribe reports nothing: it is what later ones compare with.
    func poll(_ source: ContainerSource) async {
        let began = sequence
        let containers: [DockerContainer]
        do {
            containers = try await source()
        } catch {
            log.debug("could not read the containers for events", metadata: ["error": "\(error)"])
            return
        }
        guard !subscribers.isEmpty, !Task.isCancelled else { return }
        apply(containers, readingBegan: began)
    }

    func apply(_ containers: [DockerContainer], readingBegan began: UInt64) {
        guard var previous = baseline else {
            baseline = Dictionary(containers.map { ($0.engineID, Self.observe($0)) }, uniquingKeysWith: { first, _ in first })
            return
        }
        var seen = Set<String>()
        for container in containers {
            let engineID = container.engineID
            seen.insert(engineID)
            // Changed by this service after the reading began: the reading is older than it.
            if let mark = touched[engineID], mark > began { continue }
            let now = Self.observe(container)
            defer { previous[engineID] = now }
            guard let old = previous[engineID], old.state != .removed else {
                report("create", now)
                if now.state == .running { report("start", now) }
                continue
            }
            switch (old.state, now.state) {
            case (.created, .running), (.stopped, .running):
                exitReported.remove(engineID)
                report("start", now)
            case (.running, .stopped), (.running, .created):
                if exitReported.insert(engineID).inserted { report("die", now, exitCode: container.snapshot.exitCode) }
            case (.running, .running) where old.startedDate != nil && now.startedDate != nil && old.startedDate != now.startedDate:
                // Restarted between two readings.
                report("die", now, exitCode: container.snapshot.exitCode)
                exitReported.remove(engineID)
                report("start", now)
            default:
                break
            }
            if now.state == .running, let health = now.health, health != old.health, health != "starting" {
                report("health_status: \(health)", now)
            }
        }
        for (engineID, old) in previous where !seen.contains(engineID) {
            if let mark = touched[engineID], mark > began { continue }
            previous[engineID] = nil
            touched[engineID] = nil
            // Already reported by this service.
            guard old.state != .removed else { continue }
            if old.state == .running, exitReported.insert(engineID).inserted { report("die", old) }
            exitReported.remove(engineID)
            markDestroyed(engineID)
            report("destroy", old)
        }
        // What this service changed before the reading began is in the reading now.
        touched = touched.filter { $0.value > began }
        baseline = previous
    }

    private func report(_ action: String, _ observed: Observed, exitCode: Int32? = nil) {
        var attributes = observed.attributes
        if let exitCode { attributes["exitCode"] = "\(exitCode)" }
        publish(type: "container", action: action, actorID: observed.dockerID, attributes: attributes)
    }

    static func observe(_ container: DockerContainer) -> Observed {
        let snapshot = container.snapshot
        let state: Observed.State =
            ContainerViewMapper.isRunning(snapshot) ? .running : (ContainerViewMapper.status(snapshot) == .created ? .created : .stopped)
        return Observed(
            state: state, startedDate: snapshot.startedDate, health: snapshot.health?.status.rawValue, dockerID: container.dockerID,
            attributes: attributes(container))
    }
}

/// The `filters` of `GET /events`, matched as dockerd's events filter matches them.
public struct DockerEventFilter: Sendable {
    static let accepted: Set<String> = [
        "config", "container", "daemon", "event", "image", "label", "network", "node", "plugin", "scope", "secret", "service", "type", "volume",
    ]

    let filters: [String: [String]]

    public init(_ filters: [String: [String]] = [:]) throws(DockerAPIError) {
        try DockerFilters.validate(filters, accepted: Self.accepted)
        self.filters = filters
    }

    public func includes(_ event: DockerEvent) -> Bool {
        matchesEvent(event) && exact("type", event.type) && matchesScope && matchesName(event, "daemon") && matchesName(event, "container")
            && matchesName(event, "plugin") && matchesName(event, "volume") && matchesName(event, "network") && matchesImage(event)
            && matchesName(event, "node") && matchesName(event, "service") && matchesName(event, "secret") && matchesName(event, "config")
            && DockerFilters.labelsMatch(filters["label"], event.attributes)
    }

    /// `ExactMatch`: true without values.
    private func exact(_ key: String, _ source: String) -> Bool {
        DockerFilters.exactMatch(filters[key], source)
    }

    /// `FuzzyMatch`: true without values; otherwise a value equals `source` or begins it.
    private func fuzzy(_ key: String, _ source: String) -> Bool {
        guard let values = filters[key], !values.isEmpty else { return true }
        return values.contains { source == $0 || source.hasPrefix($0) }
    }

    /// `health_status`, `exec_create` and `exec_start` match their longer actions
    /// (`health_status: healthy`) by prefix; any other event by its whole name.
    private func matchesEvent(_ event: DockerEvent) -> Bool {
        let prefixed: Set<String> = ["health_status", "exec_create", "exec_start"]
        if filters["event"]?.contains(where: prefixed.contains) == true {
            return fuzzy("event", event.action)
        }
        return exact("event", event.action)
    }

    private var matchesScope: Bool {
        guard filters["scope"] != nil else { return true }
        return exact("scope", "local")
    }

    /// A `container`, `volume`, `network` (and so on) filter matches the event's ID or its
    /// `name` attribute, by prefix: so it also holds back the events of every other type.
    private func matchesName(_ event: DockerEvent, _ key: String) -> Bool {
        fuzzy(key, event.actorID) || fuzzy(key, event.attributes["name"] ?? "")
    }

    /// An `image` filter matches an image event's ID or name, or a container event's image,
    /// with or without the tag.
    private func matchesImage(_ event: DockerEvent) -> Bool {
        let name = event.attributes[event.type == "image" ? "name" : "image"] ?? ""
        return exact("image", event.actorID) || exact("image", name) || exact("image", Self.stripTag(event.actorID))
            || exact("image", Self.stripTag(name))
    }

    /// A reference without its tag or digest.
    static func stripTag(_ reference: String) -> String {
        if let at = reference.firstIndex(of: "@") { return String(reference[..<at]) }
        let slash = reference.lastIndex(of: "/").map { reference.index(after: $0) } ?? reference.startIndex
        if let colon = reference[slash...].lastIndex(of: ":") { return String(reference[..<colon]) }
        return reference
    }
}

/// Signals by the number dockerd reports them with: Linux's, since that is where they go.
enum DockerSignals {
    static let numbers: [String: Int] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "BUS": 7, "FPE": 8, "KILL": 9, "USR1": 10, "SEGV": 11, "USR2": 12,
        "PIPE": 13, "ALRM": 14, "TERM": 15, "STKFLT": 16, "CHLD": 17, "CONT": 18, "STOP": 19, "TSTP": 20, "TTIN": 21, "TTOU": 22, "URG": 23,
        "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27, "WINCH": 28, "IO": 29, "PWR": 30, "SYS": 31,
    ]

    /// `TERM`, `SIGTERM` or `15` as `15`; a signal it does not know, as given.
    static func number(_ signal: String) -> String {
        if Int(signal) != nil { return signal }
        var name = signal.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        return numbers[name].map(String.init) ?? signal
    }
}
