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

/// What `wait` waits for.
public enum DockerWaitCondition: String, Sendable, CaseIterable {
    /// Answers at once for a container that is not running, otherwise at its exit.
    case notRunning = "not-running"
    /// Answers at the next exit, even for a container that is stopped now.
    case nextExit = "next-exit"
    /// Answers when the container is deleted, whoever deletes it.
    case removed

    /// The `condition` parameter. dockerd's default is `not-running`.
    public init(query: String?) throws(DockerAPIError) {
        guard let query, !query.isEmpty else {
            self = .notRunning
            return
        }
        guard let condition = Self(rawValue: query) else {
            throw .badRequest("invalid condition: \"\(query)\"")
        }
        self = condition
    }
}

/// `wait`'s answer: `{"StatusCode":N}`, with `Error` when the container could not run.
public struct DockerWaitResponse: Encodable, Sendable, Equatable {
    public struct Failure: Encodable, Sendable, Equatable {
        public let Message: String
    }

    public let StatusCode: Int64
    public let Error: Failure?

    public init(statusCode: Int32, error: String? = nil) {
        StatusCode = Int64(statusCode)
        Error = error.map(Failure.init(Message:))
    }
}

/// A container as `wait` sees it in the engine.
public struct DockerWaitObservation: Sendable, Equatable {
    public var running: Bool
    public var exitCode: Int32?
    public var startedAt: Date?
    public var exitedAt: Date?

    public init(running: Bool, exitCode: Int32? = nil, startedAt: Date? = nil, exitedAt: Date? = nil) {
        self.running = running
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.exitedAt = exitedAt
    }

    public init(_ snapshot: ContainerSnapshot) {
        self.init(
            running: ContainerViewMapper.isRunning(snapshot), exitCode: snapshot.exitCode, startedAt: snapshot.startedDate, exitedAt: snapshot.exitedAt)
    }
}

/// How much the wait store holds.
public struct DockerWaitLimits: Sendable {
    public var perContainer: Int
    public var total: Int
    /// How often a container this service did not start is looked at, and one it did start is
    /// looked for once it has exited and a `removed` wait is pending.
    public var pollInterval: Duration
    /// Containers this service started and remembers the last exit of.
    public var trackedContainers: Int
    /// How long `removed` waits answer later than a deletion, for the exit status of a process
    /// the deletion killed.
    public var removalGrace: Duration

    public init(
        perContainer: Int = 32, total: Int = 512, pollInterval: Duration = .seconds(1), trackedContainers: Int = 1024,
        removalGrace: Duration = .seconds(10)
    ) {
        self.perContainer = perContainer
        self.total = total
        self.pollInterval = pollInterval
        self.trackedContainers = trackedContainers
        self.removalGrace = removalGrace
    }
}

/// A registered `wait`.
public struct DockerWaitTicket: Sendable, Hashable {
    let id: UInt64
    public let engineID: String
}

/// The `wait` state machine.
///
/// For a process this service started, the store itself is the authority: the start marks the
/// container running here before the process starts, and the process's own exit status is
/// published here when it ends. A wait is checked against that state and registered in one
/// step of the actor, so an exit can come before the registration or after it, never between
/// the check and the registration where it would be lost.
///
/// A container this service did not start (one `container run` started, or one started before
/// this service was) is looked at in the engine once a second while someone waits on it. A
/// deletion is published by the route that deletes; one the engine does on its own (`--rm`) or
/// that another client does is seen by the same polling.
public actor DockerWaitStore {
    /// The engine's view of a container; nil once it is gone.
    public typealias Observe = @Sendable (_ engineID: String) async throws -> DockerWaitObservation?

    private struct Tracked {
        var running: Bool
        var lastCode: Int32?
        var lastError: String?
        /// Deleted while its process ran: `removed` answers come with the exit the deletion
        /// causes, which the process's monitor publishes a moment later.
        var removal: Removal?
    }

    private struct Removal {
        let failure: String?
        let fallback: Task<Void, Never>
    }

    private struct Waiter {
        let ticket: DockerWaitTicket
        let condition: DockerWaitCondition
        /// What the engine showed when the wait began, for a container only polling can follow.
        /// Nil until the first look when the store's own state was used instead.
        var baseline: DockerWaitObservation?
        /// The container was seen running since the wait began, so stopping now is an exit.
        var sawRunning = false
        /// The last status seen, which a `removed` wait answers with.
        var lastCode: Int32?
        var response: DockerWaitResponse?
        var continuation: CheckedContinuation<DockerWaitResponse?, Never>?
    }

    private var tracked: [String: Tracked] = [:]
    private var waiters: [UInt64: Waiter] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0
    private var stopped = false
    private let observe: Observe
    public let limits: DockerWaitLimits

    public init(limits: DockerWaitLimits = .init(), observe: @escaping Observe) {
        self.limits = limits
        self.observe = observe
    }

    /// Waits not yet answered and handed back.
    public var pending: Int { waiters.count }

    /// Containers being polled.
    public var polling: Int { pollers.count }

    // MARK: Registering

    /// Registers a wait on `engineID`, which the engine showed as `observed` just before.
    /// Answered at once when the condition already holds.
    public func register(engineID: String, condition: DockerWaitCondition, observed: DockerWaitObservation) throws(DockerAPIError) -> DockerWaitTicket {
        guard !stopped else {
            throw DockerAPIError(.serviceUnavailable, "the Docker API service is stopping")
        }
        guard waiters.values.filter({ $0.ticket.engineID == engineID }).count < limits.perContainer else {
            throw DockerAPIError(.tooManyRequests, "container \(engineID) already has \(limits.perContainer) waits")
        }
        guard waiters.count < limits.total else {
            throw DockerAPIError(.tooManyRequests, "too many waits are pending")
        }
        nextID += 1
        let ticket = DockerWaitTicket(id: nextID, engineID: engineID)
        var waiter = Waiter(ticket: ticket, condition: condition)
        if let known = tracked[engineID] {
            waiter.lastCode = known.lastCode
            if condition == .notRunning, !known.running {
                waiter.response = DockerWaitResponse(statusCode: known.lastCode ?? observed.exitCode ?? 0, error: known.lastError)
            }
        } else {
            waiter.baseline = observed
            waiter.lastCode = observed.exitCode
            if condition == .notRunning, !observed.running {
                waiter.response = DockerWaitResponse(statusCode: observed.exitCode ?? 0)
            }
        }
        waiters[ticket.id] = waiter
        updatePolling(engineID)
        return ticket
    }

    /// The answer to `ticket`, once there is one. Nil when the wait was cancelled or the
    /// service is stopping. Cancelling the calling task (its client left) forgets the wait.
    public func response(_ ticket: DockerWaitTicket) async -> DockerWaitResponse? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                suspend(ticket, continuation)
            }
        } onCancel: {
            Task { await self.cancel(ticket) }
        }
    }

    private func suspend(_ ticket: DockerWaitTicket, _ continuation: CheckedContinuation<DockerWaitResponse?, Never>) {
        guard var waiter = waiters[ticket.id] else {
            continuation.resume(returning: nil)
            return
        }
        if let response = waiter.response {
            waiters[ticket.id] = nil
            updatePolling(ticket.engineID)
            continuation.resume(returning: response)
            return
        }
        waiter.continuation = continuation
        waiters[ticket.id] = waiter
    }

    /// Forgets a wait whose client left.
    public func cancel(_ ticket: DockerWaitTicket) {
        guard let waiter = waiters.removeValue(forKey: ticket.id) else { return }
        waiter.continuation?.resume(returning: nil)
        updatePolling(ticket.engineID)
    }

    // MARK: Publishing

    /// A process this service is about to start in `engineID`. Called before the process
    /// starts, so that no `not-running` wait registered from here on answers with the last
    /// exit.
    public func starting(_ engineID: String) {
        var known = tracked[engineID] ?? Tracked(running: true)
        known.running = true
        known.lastError = nil
        tracked[engineID] = known
        bound()
        for id in ids(of: engineID) {
            waiters[id]?.sawRunning = true
        }
        updatePolling(engineID)
    }

    /// The process this service started in `engineID` exited with `code`.
    public func exited(_ engineID: String, code: Int32) {
        guard let known = tracked[engineID] else { return }
        tracked[engineID] = Tracked(running: false, lastCode: code)
        let response = DockerWaitResponse(statusCode: code)
        for id in ids(of: engineID) {
            waiters[id]?.lastCode = code
            if waiters[id]?.condition != .removed {
                resolve(id, response)
            }
        }
        if let removal = known.removal {
            // Deleted while it ran: this was the exit the deletion caused.
            removal.fallback.cancel()
            finishRemoval(engineID, failure: removal.failure)
            return
        }
        updatePolling(engineID)
    }

    /// The start of `engineID` failed. Waits for its exit answer with the error, as dockerd's
    /// do, with the status dockerd gives a container that could not start.
    public func startFailed(_ engineID: String, message: String) {
        let code: Int32 = 128
        tracked[engineID] = Tracked(running: false, lastCode: code, lastError: message)
        let response = DockerWaitResponse(statusCode: code, error: message)
        for id in ids(of: engineID) {
            waiters[id]?.lastCode = code
            if waiters[id]?.condition != .removed {
                resolve(id, response)
            }
        }
        updatePolling(engineID)
    }

    /// The process this service started in `engineID` can no longer be waited on (the engine
    /// went away under it): follow the container by polling instead.
    public func lost(_ engineID: String) {
        guard tracked.removeValue(forKey: engineID) != nil else { return }
        for id in ids(of: engineID) {
            // It was running when its process was lost, so stopping is its exit.
            waiters[id]?.sawRunning = true
        }
        updatePolling(engineID)
    }

    /// `engineID` was deleted. Every wait on it answers, with its last exit status. One whose
    /// process this service started and is still running answers with that process's exit,
    /// which the deletion causes, or after `removalGrace` without it.
    public func removed(_ engineID: String, failure: String? = nil) {
        if var known = tracked[engineID], known.running {
            guard known.removal == nil else { return }
            let grace = limits.removalGrace
            let fallback = Task { [weak self] in
                do {
                    try await Task.sleep(for: grace)
                } catch {
                    return
                }
                await self?.finishRemoval(engineID, failure: failure)
            }
            known.removal = Removal(failure: failure, fallback: fallback)
            tracked[engineID] = known
            return
        }
        finishRemoval(engineID, failure: failure)
    }

    private func finishRemoval(_ engineID: String, failure: String?) {
        let known = tracked.removeValue(forKey: engineID)
        known?.removal?.fallback.cancel()
        for id in ids(of: engineID) {
            let code = known?.lastCode ?? waiters[id]?.lastCode ?? 0
            resolve(id, DockerWaitResponse(statusCode: code, error: failure ?? known?.lastError))
        }
        updatePolling(engineID)
    }

    /// Answers every pending wait with nothing and stops polling.
    public func shutdown() {
        stopped = true
        for (id, waiter) in waiters {
            waiter.continuation?.resume(returning: nil)
            waiters[id] = nil
        }
        for poller in pollers.values {
            poller.cancel()
        }
        pollers = [:]
        for known in tracked.values {
            known.removal?.fallback.cancel()
        }
    }

    // MARK: Internals

    private func ids(of engineID: String) -> [UInt64] {
        waiters.filter { $0.value.ticket.engineID == engineID && $0.value.response == nil }.map(\.key).sorted()
    }

    private func resolve(_ id: UInt64, _ response: DockerWaitResponse) {
        guard var waiter = waiters[id], waiter.response == nil else { return }
        if let continuation = waiter.continuation {
            waiters[id] = nil
            continuation.resume(returning: response)
        } else {
            // Registered, but its response body has not started waiting yet.
            waiter.response = response
            waiters[id] = waiter
        }
    }

    /// Forgets the oldest stopped containers' exits once there are too many.
    private func bound() {
        guard tracked.count > limits.trackedContainers else { return }
        for (engineID, known) in tracked where !known.running && ids(of: engineID).isEmpty {
            tracked[engineID] = nil
            if tracked.count <= limits.trackedContainers { return }
        }
    }

    /// Whether only the engine can tell what happens next to `engineID`: a wait is pending on
    /// it, and no process this service started is running in it.
    private func needsPolling(_ engineID: String) -> Bool {
        guard !stopped, !ids(of: engineID).isEmpty else { return false }
        return tracked[engineID]?.running != true
    }

    private func updatePolling(_ engineID: String) {
        if needsPolling(engineID) {
            guard pollers[engineID] == nil else { return }
            let interval = limits.pollInterval
            let observe = self.observe
            pollers[engineID] = Task { [weak self] in
                while true {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    let observation: Result<DockerWaitObservation?, any Error>
                    do {
                        observation = .success(try await observe(engineID))
                    } catch {
                        observation = .failure(error)
                    }
                    guard let self, await self.apply(engineID, observation) else { return }
                }
            }
        } else if let poller = pollers.removeValue(forKey: engineID) {
            poller.cancel()
        }
    }

    /// One look at `engineID` in the engine. Returns whether to keep looking.
    private func apply(_ engineID: String, _ result: Result<DockerWaitObservation?, any Error>) -> Bool {
        guard needsPolling(engineID) else {
            pollers[engineID] = nil
            return false
        }
        // An engine that did not answer this time may next time.
        guard case .success(let observation) = result else { return true }
        guard let observation else {
            removed(engineID)
            pollers[engineID] = nil
            return false
        }
        for id in ids(of: engineID) {
            guard var waiter = waiters[id] else { continue }
            let baseline = waiter.baseline ?? observation
            waiter.baseline = baseline
            if observation.running {
                waiter.sawRunning = true
                waiters[id] = waiter
                continue
            }
            if let code = observation.exitCode { waiter.lastCode = code }
            waiters[id] = waiter
            let exited =
                waiter.sawRunning || observation.exitedAt != baseline.exitedAt || observation.startedAt != baseline.startedAt
            switch waiter.condition {
            case .notRunning:
                resolve(id, DockerWaitResponse(statusCode: observation.exitCode ?? 0))
            case .nextExit where exited:
                resolve(id, DockerWaitResponse(statusCode: observation.exitCode ?? 0))
            case .nextExit, .removed:
                break
            }
        }
        if needsPolling(engineID) { return true }
        pollers[engineID] = nil
        return false
    }
}
