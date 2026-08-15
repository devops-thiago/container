//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// Ties the engine's lifetime to the lifetime of the app that owns it.
///
/// The API server is a launchd agent, so it is not a child of the host app: its parent is
/// launchd. A force quit sends SIGKILL to the app alone — nothing cascades, and the app gets
/// no chance to run the teardown its own Quit path performs. So the rule that the engine
/// lives only while the app lives can only be enforced from this side, the one still running
/// when the app is killed. The app names itself owner on every health ping; this watchdog
/// polls that process and shuts the engine down once it is gone.
///
/// Having no owner is a normal state rather than only a dying one. launchd demand-starts the
/// agent on any XPC dial, including one from a CLI invoked with no app running, so an engine
/// nobody owns refuses work and exits on its own. That is what makes the CLI report the
/// system as down instead of quietly resurrecting an engine the user never opened.
public actor OwnerWatchdog {
    /// How long the engine waits for a lost owner before shutting down. Generous, because a
    /// force quit is usually followed by reopening the app: re-attaching to the engine that
    /// is already up is faster for the user, and keeps their containers, where tearing down
    /// and rebuilding would cost a full boot.
    public static let graceAfterOwnerLoss = Duration.seconds(30)

    /// How long a freshly started engine waits to be claimed by anyone. Shorter than the
    /// above because nothing is running yet and nothing is lost by leaving: this is the
    /// demand-started-by-the-CLI case, where the right answer is to go away again.
    public static let graceBeforeFirstOwner = Duration.seconds(20)

    private let poll: Duration
    private let log: Logger
    private let isAlive: @Sendable (pid_t) -> Bool

    private var owner: pid_t?
    private var deadline: ContinuousClock.Instant
    private var expired = false
    /// Whether an app ever claimed this engine, which is what separates the two ways of
    /// having no owner: an engine whose app was just killed is mid-reprieve and still has to
    /// work, while one nobody ever claimed is a CLI demand-start and has to refuse.
    private var everOwned = false

    public init(
        now: ContinuousClock.Instant = ContinuousClock.now,
        poll: Duration = .seconds(1),
        isAlive: @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM },
        log: Logger
    ) {
        self.poll = poll
        self.isAlive = isAlive
        self.log = log
        self.deadline = now.advanced(by: Self.graceBeforeFirstOwner)
    }

    /// Name `pid` as this engine's owner.
    ///
    /// Carried on every health ping rather than claimed once, so it doubles as the re-claim
    /// for an engine that outlived a force quit: the relaunched app pings, the countdown
    /// started by the old owner's death is cancelled, and the same engine carries on.
    public func attach(pid: pid_t) {
        guard pid > 0, !expired else { return }
        if owner != pid {
            log.info("engine owner attached", metadata: ["pid": "\(pid)"])
        }
        owner = pid
        everOwned = true
    }

    /// Whether the engine may still do work.
    ///
    /// True through the whole reprieve, not just while the owner is breathing: the engine
    /// stays up after a force quit precisely so the relaunched app can adopt it with its
    /// workloads intact, and an engine that refused every request in that window would be
    /// up in name only. What it does not survive is the deadline, or never having been
    /// claimed at all.
    public func isOwned() -> Bool { everOwned && !expired }

    /// Refuse a route while the engine is unowned.
    ///
    /// The health ping is deliberately left ungated: it is the message that carries the
    /// ownership claim, so gating it would make the engine unclaimable, and it is also how a
    /// client asks whether the engine is there at all.
    public nonisolated func wrap(_ handler: @escaping XPCServer.RouteHandler) -> XPCServer.RouteHandler {
        { message, session in
            guard await self.isOwned() else {
                throw ContainerizationError(
                    .invalidState,
                    message: "the container engine has no running app; open SiliconShip to start it"
                )
            }
            return try await handler(message, session)
        }
    }

    /// One poll step, exposed for tests. Returns whether the engine should now shut down.
    func tick(now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        if expired { return true }
        if let pid = owner {
            // A live owner continuously renews the grace, so the deadline below is only ever
            // reached after the owner has actually gone.
            if isAlive(pid) {
                deadline = now.advanced(by: Self.graceAfterOwnerLoss)
                return false
            }
            log.info("engine owner exited", metadata: ["pid": "\(pid)"])
            owner = nil
        }
        guard now >= deadline else { return false }
        expired = true
        return true
    }

    /// Poll until the engine has been ownerless past its grace, then return so the caller can
    /// shut down. Never returns while an owner is alive.
    public func waitForOwnerLoss() async {
        while !tick() {
            do {
                try await Task.sleep(for: poll)
            } catch {
                return
            }
        }
    }
}
