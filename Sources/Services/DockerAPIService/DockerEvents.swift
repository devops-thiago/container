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
    /// How often the engine's containers are read while anyone is subscribed, when the engine
    /// has no events route to follow.
    public var pollInterval: Duration
    /// How long the containers are read that way before the engine is asked again whether it
    /// has the route: it may have been replaced by one that does.
    public var engineRecheck: Duration
    /// How long to wait before following the engine again after its stream ended.
    public var reconnectDelay: Duration

    public init(
        maxSubscribers: Int = 64, bufferedEvents: Int = 1024, pollInterval: Duration = .seconds(1), engineRecheck: Duration = .seconds(5),
        reconnectDelay: Duration = .milliseconds(100)
    ) {
        self.maxSubscribers = maxSubscribers
        self.bufferedEvents = bufferedEvents
        self.pollInterval = pollInterval
        self.engineRecheck = engineRecheck
        self.reconnectDelay = reconnectDelay
    }
}

/// A subscription to the engine's container events (`ContainerClient.events`).
public struct DockerEngineEvents: Sendable {
    public var processNonce: String
    /// Where to resume from when no event has been read.
    public var cursor: UInt64
    /// What came after the cursor asked with is not all there: list again.
    public var gap: Bool
    public var events: AsyncThrowingStream<ContainerEvent, any Error>

    public init(processNonce: String, cursor: UInt64, gap: Bool, events: AsyncThrowingStream<ContainerEvent, any Error>) {
        self.processNonce = processNonce
        self.cursor = cursor
        self.gap = gap
        self.events = events
    }
}

/// The engine's container events, for an engine that has them.
public protocol DockerEngineEventFeed: Sendable {
    /// Whether the engine running now has the events route; nil when it does not answer.
    func available() async -> Bool?
    /// Subscribe, resuming after `since` when it is given.
    func subscribe(since: ContainerEventCursor?) async throws -> DockerEngineEvents
}

/// The events this service reports, to the clients streaming `/events`.
///
/// A container's events are the engine's, from its events route, while anyone is subscribed
/// (#230): the engine writes each where it makes the change, whoever asked for it. The engine's
/// stream is followed from the last event read when it ends, and when the engine is replaced
/// or more was missed than it keeps, the containers are read again and what changed meanwhile
/// is reported from the difference. What this service does to images, volumes and networks is
/// reported as it does it, and so is a container's `restart`, which the engine has no verb for.
///
/// An engine without the route (an older one) is read once a second instead, as stage A did:
/// what this service does itself is reported as it does it, and everything else is found by
/// comparing each reading with the last: a container that appeared, started, died, changed
/// health or went. A change this service reported itself is not reported again by the
/// reading that follows. The engine is asked again every few seconds whether it has the route.
/// Nothing is kept for a client that was not subscribed: there is no history.
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
    private let feed: (any DockerEngineEventFeed)?
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
    /// The engine's events are being followed: a container's changes are the engine's to report.
    public private(set) var followingEngine = false
    /// Where the engine's stream was left, to resume from.
    private var cursor: ContainerEventCursor?
    /// Containers this service is removing and making again under the same ID (a network
    /// connect), whose engine `destroy` and `create` are not changes a client sees. By engine ID,
    /// the incarnation removed. Bounded.
    private var recreating: [String: String] = [:]
    private static let recreatingKept = 64

    /// The actions the engine reports for a container, which this service does not report again
    /// while it follows the engine.
    static let engineActions: Set<String> = ["create", "start", "die", "destroy", "rename", "kill", "stop"]

    /// - Parameter source: the containers to read while anyone is subscribed, as the container
    ///   routes see them; nil reports only what this service does.
    /// - Parameter feed: the engine's container events, followed while anyone is subscribed and
    ///   the engine has them; `source` is read instead when it does not.
    public init(
        limits: DockerEventLimits = .init(), log: Logger = Logger(label: "DockerAPIService"), now: @escaping @Sendable () -> Date = { Date() },
        source: ContainerSource? = nil, feed: (any DockerEngineEventFeed)? = nil
    ) {
        self.limits = limits
        self.source = source
        self.feed = feed
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
        // The engine reports it, whoever made it.
        if followingEngine && (Self.engineActions.contains(action) || action.hasPrefix("health_status")) { return }
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
        guard poller == nil else { return }
        if feed != nil {
            poller = Task { [weak self] in await self?.follow() }
            return
        }
        guard let source else { return }
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
        followingEngine = false
        cursor = nil
        recreating = [:]
    }

    // MARK: Following the engine

    /// Follows the engine's events while it has them, and reads its containers while it does
    /// not, until no one is subscribed.
    private func follow() async {
        guard let feed else { return }
        while !Task.isCancelled {
            guard await feed.available() == true, !Task.isCancelled else {
                followingEngine = false
                await pollFor(limits.engineRecheck)
                continue
            }
            let subscription: DockerEngineEvents
            do {
                subscription = try await feed.subscribe(since: cursor)
            } catch {
                log.debug("could not follow the engine's events", metadata: ["error": "\(error)"])
                followingEngine = false
                await pollFor(limits.engineRecheck)
                continue
            }
            guard !Task.isCancelled else { return }
            followingEngine = true
            let resumed = cursor != nil && !subscription.gap
            if !resumed {
                cursor = ContainerEventCursor(processNonce: subscription.processNonce, sequence: subscription.cursor)
                // What changed while nothing was followed, from the difference; or, on the first
                // subscription, the reading the next one compares with. Read after subscribing,
                // so that nothing between the two is missed.
                if let source { await poll(source) }
            }
            do {
                for try await event in subscription.events {
                    guard !Task.isCancelled else { return }
                    cursor = ContainerEventCursor(processNonce: subscription.processNonce, sequence: event.sequence)
                    apply(event)
                }
            } catch {
                log.debug("the engine's events ended", metadata: ["error": "\(error)"])
            }
            // The engine went, or this fell behind it: follow it again from where this was.
            try? await Task.sleep(for: limits.reconnectDelay)
        }
    }

    /// Reads the containers once a poll interval for `duration`.
    private func pollFor(_ duration: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: duration)
        repeat {
            if let source { await poll(source) }
            try? await Task.sleep(for: limits.pollInterval)
        } while !Task.isCancelled && ContinuousClock.now < deadline
    }

    /// Reports an engine event, and keeps the last reading current with it so that a later
    /// difference starts from here.
    func apply(_ event: ContainerEvent) {
        let engineID = event.id
        if let removed = recreating[engineID] {
            switch event.action {
            case .destroy where event.incarnation == removed:
                return
            case .create where event.incarnation != removed:
                recreating[engineID] = nil
                if var observed = baseline?[engineID] {
                    observed.attributes = Self.attributes(event)
                    baseline?[engineID] = observed
                }
                return
            default:
                break
            }
        }
        guard let message = Self.dockerEvent(event) else { return }
        switch event.action {
        case .create, .start:
            exitReported.remove(engineID)
            destroyed.removeAll { $0 == engineID }
        case .die:
            exitReported.insert(engineID)
        case .destroy:
            exitReported.remove(engineID)
            markDestroyed(engineID)
        default:
            break
        }
        if baseline != nil {
            var observed =
                baseline?[engineID] ?? Observed(state: .created, dockerID: message.actorID, attributes: Self.attributes(event))
            observed.attributes = Self.attributes(event)
            switch event.action {
            case .create: observed.state = .created
            case .start: observed.state = .running
            case .die: observed.state = .stopped
            case .healthStatus: observed.health = event.health?.rawValue
            default: break
            }
            if event.action == .destroy {
                baseline?[engineID] = nil
            } else {
                baseline?[engineID] = observed
            }
        }
        publish(message)
    }

    /// This service is about to remove `container` and make it again under the same ID, which
    /// is not a change a client sees.
    public func recreating(_ container: DockerContainer) {
        // Read from the engine's containers instead, a recreate is not seen as one.
        guard followingEngine else { return }
        recreating[container.engineID] = container.snapshot.incarnation
        if recreating.count > Self.recreatingKept, let any = recreating.keys.sorted().first {
            recreating[any] = nil
        }
    }

    /// The recreate of `engineID` did not happen after all.
    public func recreateEnded(_ engineID: String) {
        recreating[engineID] = nil
    }

    /// An engine event as dockerd reports a container's: its labels, image and name as
    /// attributes, read from the event itself, since the container may be gone by now.
    static func dockerEvent(_ event: ContainerEvent) -> DockerEvent? {
        var attributes = attributes(event)
        let action: String
        switch event.action {
        case .healthStatus:
            guard let health = event.health else { return nil }
            action = "health_status: \(health.rawValue)"
        case .die:
            action = event.action.rawValue
            if let code = event.exitCode { attributes["exitCode"] = "\(code)" }
        case .kill:
            action = event.action.rawValue
            if let signal = event.attributes["signal"] { attributes["signal"] = DockerSignals.number(signal) }
        case .rename:
            action = event.action.rawValue
            if let old = event.attributes["oldName"] { attributes["oldName"] = "/" + old }
        default:
            action = event.action.rawValue
        }
        return DockerEvent(type: "container", action: action, actorID: dockerID(event), attributes: attributes, time: event.time)
    }

    /// The Docker ID of an event's container: the one this service gave it, or the hash of its
    /// engine ID for one it did not make.
    static func dockerID(_ event: ContainerEvent) -> String {
        if let id = event.labels[DockerLabels.id], DockerIdentityTable.isDockerID(id), id.hasPrefix(event.id) {
            return id
        }
        return DockerIdentityTable.foreignID(engineID: event.id)
    }

    /// The attributes of an event's container, as `attributes(_: DockerContainer)` makes them.
    static func attributes(_ event: ContainerEvent) -> [String: String] {
        var attributes = event.labels.filter { !$0.key.hasPrefix(DockerLabels.prefix) }
        attributes["image"] = event.labels[DockerLabels.image] ?? ContainerViewMapper.shortReference(event.image)
        attributes["name"] = DockerIdentityTable.engineName(id: event.id, labels: event.labels)
        return attributes
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
