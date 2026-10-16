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

import NIOHTTP1

/// The streams an attach asks for, from its query.
public struct DockerAttachOptions: Sendable, Equatable {
    public var stdin: Bool
    public var stdout: Bool
    public var stderr: Bool

    public init(stdin: Bool = false, stdout: Bool = false, stderr: Bool = false) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// How much the attach store holds.
public struct DockerAttachLimits: Sendable {
    /// Attaches waiting for one container's start.
    public var perContainer: Int
    /// Attaches waiting for any start.
    public var total: Int
    /// How long an attach waits for its container to start before it is let go.
    public var idleTimeout: Duration
    /// How often a waiting attach checks that its client is still connected.
    public var peerCheckInterval: Duration
    /// How long a start waits for an attach whose upgrade it already counted to hand over its
    /// connection.
    public var handover: Duration

    public init(
        perContainer: Int = 4, total: Int = 64, idleTimeout: Duration = .seconds(120), peerCheckInterval: Duration = .seconds(1),
        handover: Duration = .seconds(2)
    ) {
        self.perContainer = perContainer
        self.total = total
        self.idleTimeout = idleTimeout
        self.peerCheckInterval = peerCheckInterval
        self.handover = handover
    }
}

/// One attach's place in the store, taken by its route before the `101` goes out.
public struct DockerAttachTicket: Sendable, Hashable {
    let id: UInt64
    public let engineID: String
}

/// An attach a start took, with the connection its output goes to.
public struct DockerParkedAttach: Sendable {
    public let ticket: DockerAttachTicket
    public let options: DockerAttachOptions
    public let stream: DockerHijackedStream
}

/// How a parked attach ended.
public enum DockerAttachOutcome: Sendable, Equatable {
    /// A start bridged it to the process, which has exited.
    case served
    /// Nothing started the container before the attach was let go: its client left, it waited
    /// too long, the container was deleted, the start failed, or the service is stopping.
    case released
}

/// Attaches waiting for their container to start.
///
/// The engine binds a process's stdio when it bootstraps it, so an attach can only be served by
/// the start that follows it: the start makes pipes, binds them, and bridges each parked
/// connection to them. Until then the connection waits here, unread: what the client types
/// early stays in the connection's own bounded buffer, in order, and so does an early end of
/// its input.
///
/// The route takes a ticket before it answers `101`, so a start that arrives before the
/// upgraded connection has been handed over still counts the attach and waits a moment for
/// it. Everything here is bounded: a few attaches per container, an overall cap, and an idle
/// timeout. A waiting attach is let go when its client hangs up, when its container is deleted,
/// and when the service stops.
public actor DockerAttachStore {
    private struct Slot {
        let ticket: DockerAttachTicket
        let options: DockerAttachOptions
        var stream: DockerHijackedStream?
        var claimed = false
        var continuation: CheckedContinuation<DockerAttachOutcome, Never>?
        /// Decided before the attach's connection arrived to wait for it.
        var outcome: DockerAttachOutcome?
        var timer: Task<Void, Never>?
        var watcher: Task<Void, Never>?
    }

    private var slots: [UInt64: Slot] = [:]
    private var nextID: UInt64 = 0
    private var stopped = false
    public let limits: DockerAttachLimits

    public init(limits: DockerAttachLimits = .init()) {
        self.limits = limits
    }

    /// Attaches held for `engineID` that no start has taken.
    public func waiting(for engineID: String) -> Int {
        slots.values.filter { $0.ticket.engineID == engineID && !$0.claimed }.count
    }

    /// Every attach held, taken or not.
    public var count: Int { slots.count }

    /// Takes a place for an attach to `engineID`. Refused past the limits.
    public func reserve(engineID: String, options: DockerAttachOptions) throws(DockerAPIError) -> DockerAttachTicket {
        guard !stopped else {
            throw DockerAPIError(.serviceUnavailable, "the Docker API service is stopping")
        }
        guard waiting(for: engineID) < limits.perContainer else {
            throw DockerAPIError(
                .tooManyRequests, "container \(engineID) already has \(limits.perContainer) attaches waiting for it to start")
        }
        guard slots.count < limits.total else {
            throw DockerAPIError(.tooManyRequests, "too many attaches are waiting for containers to start")
        }
        nextID += 1
        let ticket = DockerAttachTicket(id: nextID, engineID: engineID)
        var slot = Slot(ticket: ticket, options: options)
        let timeout = limits.idleTimeout
        slot.timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.expire(ticket.id)
        }
        slots[ticket.id] = slot
        return ticket
    }

    /// Hands over the upgraded connection for `ticket` and waits until the attach is over.
    public func park(_ ticket: DockerAttachTicket, stream: DockerHijackedStream) async -> DockerAttachOutcome {
        guard var slot = slots[ticket.id] else { return .released }
        if let outcome = slot.outcome {
            remove(ticket.id)
            return outcome
        }
        slot.stream = stream
        if !slot.claimed {
            let interval = limits.peerCheckInterval
            slot.watcher = Task { [weak self] in
                while true {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    if await !stream.peerConnected() {
                        await self?.disconnected(ticket.id)
                        return
                    }
                }
            }
        }
        slots[ticket.id] = slot
        return await withCheckedContinuation { continuation in
            slots[ticket.id]?.continuation = continuation
        }
    }

    /// Takes every attach waiting for `engineID`, for the start that is about to bind its
    /// stdio. An attach whose connection has not been handed over yet is waited for, briefly.
    public func claim(engineID: String) async -> [DockerParkedAttach] {
        var ids: [UInt64] = []
        for (id, slot) in slots.sorted(by: { $0.key < $1.key }) where slot.ticket.engineID == engineID && !slot.claimed && slot.outcome == nil {
            slots[id]?.claimed = true
            slots[id]?.watcher?.cancel()
            slots[id]?.watcher = nil
            ids.append(id)
        }
        guard !ids.isEmpty else { return [] }
        let deadline = ContinuousClock.now.advanced(by: limits.handover)
        while ContinuousClock.now < deadline, ids.contains(where: { slots[$0] != nil && slots[$0]?.stream == nil }) {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                break
            }
        }
        var claimed: [DockerParkedAttach] = []
        for id in ids {
            guard let slot = slots[id] else { continue }
            guard let stream = slot.stream else {
                // Its connection never came: let it go when it does.
                finish(id, .released)
                continue
            }
            claimed.append(DockerParkedAttach(ticket: slot.ticket, options: slot.options, stream: stream))
        }
        return claimed
    }

    /// Ends attaches a start took.
    public func complete(_ tickets: [DockerAttachTicket], _ outcome: DockerAttachOutcome) {
        for ticket in tickets {
            finish(ticket.id, outcome)
        }
    }

    /// Lets go of every attach still waiting for `engineID`: its container was deleted.
    public func release(engineID: String) {
        for (id, slot) in slots where slot.ticket.engineID == engineID && !slot.claimed {
            finish(id, .released)
        }
    }

    /// Lets go of every attach still waiting, and refuses new ones.
    public func shutdown() {
        stopped = true
        for (id, slot) in slots where !slot.claimed {
            finish(id, .released)
        }
    }

    private func expire(_ id: UInt64) {
        guard let slot = slots[id] else { return }
        if slot.continuation == nil {
            // Its connection never arrived to wait: the upgrade failed, or it has already been
            // told its outcome. Should it arrive now, it finds no place and is let go.
            remove(id)
        } else if !slot.claimed {
            finish(id, .released)
        }
    }

    private func disconnected(_ id: UInt64) {
        guard let slot = slots[id], !slot.claimed else { return }
        finish(id, .released)
    }

    private func finish(_ id: UInt64, _ outcome: DockerAttachOutcome) {
        guard var slot = slots[id] else { return }
        if let continuation = slot.continuation {
            remove(id)
            continuation.resume(returning: outcome)
        } else {
            // Its connection has not arrived yet; it hears the outcome when it does, or the
            // idle timer forgets it.
            slot.outcome = outcome
            slot.watcher?.cancel()
            slot.watcher = nil
            slots[id] = slot
        }
    }

    private func remove(_ id: UInt64) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.timer?.cancel()
        slot.watcher?.cancel()
    }
}
