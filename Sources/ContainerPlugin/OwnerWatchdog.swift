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

import AppKit
import ContainerVersion
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// Ties a service's lifetime to the lifetime of the app it belongs to.
///
/// Every engine service is a launchd agent, so none of them is a child of the host app: their
/// parent is launchd. A force quit sends SIGKILL to the app alone — nothing cascades, and the
/// app gets no chance to run the teardown its own Quit path performs. So the rule that the
/// engine lives only while the app lives can only be enforced from this side, the one still
/// running when the app is killed. Each service watches for the app and stops once it is gone.
///
/// The app is looked up rather than announcing itself. An ownership handshake would have to be
/// invented separately for every service the CLI dials directly — `machine-apiserver` and
/// `container-core-images` have no health route to carry a claim — whereas asking Launch
/// Services costs one call, needs no protocol, and no app-side code at all.
///
/// Having no app is a normal state rather than only a dying one. launchd demand-starts an agent
/// on any XPC dial, including one from a CLI invoked with no app running, so a service nobody
/// owns refuses work and exits on its own. That is what makes the CLI report the system as down
/// instead of quietly resurrecting an engine the user never opened.
public actor OwnerWatchdog {
    /// How long a service waits after the app disappears before shutting down. Generous,
    /// because a force quit is usually followed by reopening the app: adopting the engine that
    /// is already up is faster for the user and keeps their containers, where tearing down and
    /// rebuilding would cost a full boot.
    public static let graceAfterOwnerLoss = Duration.seconds(30)

    /// How long a freshly started service waits to see the app at all. Shorter than the above
    /// because nothing is running yet and nothing is lost by leaving: this is the
    /// demand-started-by-the-CLI case, where the right answer is to go away again.
    public static let graceBeforeFirstOwner = Duration.seconds(20)

    private let poll: Duration
    private let log: Logger
    private let appIsRunning: @Sendable () -> Bool

    private var deadline: ContinuousClock.Instant
    private var expired = false
    /// Whether the app was ever seen, which is what separates the two ways of not having one:
    /// a service whose app was just killed is mid-reprieve and still has to work, while one
    /// that never saw an app is a CLI demand-start and has to refuse.
    private var everSeen = false
    private var reportedLoss = false

    /// - Parameter appIsRunning: whether the owning app is up. The default asks Launch Services
    ///   for the bundle identifier baked into this executable, and returns true when there is
    ///   no such identifier — a standalone `container` install has no app to outlive, so it
    ///   keeps the upstream behaviour of running until stopped.
    public init(
        now: ContinuousClock.Instant = ContinuousClock.now,
        poll: Duration = .seconds(1),
        appIsRunning: (@Sendable () -> Bool)? = nil,
        log: Logger
    ) {
        self.poll = poll
        self.appIsRunning = appIsRunning ?? Self.hostAppIsRunning
        self.log = log
        self.deadline = now.advanced(by: Self.graceBeforeFirstOwner)
    }

    /// Whether the engine is embedded in an app whose life it should follow at all.
    public static var isEnforceable: Bool { ServiceIdentity.hostAppBundleIdentifier != nil }

    /// Ask Launch Services whether the host app is running.
    ///
    /// Deliberately *not* `NSWorkspace.shared.runningApplications`: that array is a
    /// KVO-maintained cache that only refreshes on a live main run loop, which a `dispatchMain`
    /// launchd agent never provides. Measured in spike S9, it kept reporting a force-quit app
    /// as running indefinitely, while this call tracked the app across kill and relaunch
    /// exactly — and reading a dead app as alive is the one answer a lifetime watch must never
    /// give.
    private static let hostAppIsRunning: @Sendable () -> Bool = {
        guard let bundleID = ServiceIdentity.hostAppBundleIdentifier else { return true }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Whether the service may still do work.
    ///
    /// True through the whole reprieve, not only while the app is up: a service stays alive
    /// after a force quit precisely so the relaunched app can adopt it with its workloads
    /// intact, and one that refused every request in that window would be up in name only.
    /// What it does not survive is the deadline, or never having seen an app at all.
    public func isOwned() -> Bool { everSeen && !expired }

    /// Refuse a route while no app owns this service.
    ///
    /// Exempt whatever a client uses purely to ask whether the engine is there, and whatever
    /// the engine needs to assemble itself — helpers announcing endpoints are not user work.
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

    /// One poll step, exposed for tests. Returns whether the service should now shut down.
    func tick(now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        if expired { return true }
        if appIsRunning() {
            if !everSeen {
                log.info("owning app found")
            } else if reportedLoss {
                log.info("owning app came back")
            }
            everSeen = true
            reportedLoss = false
            // A running app continuously renews the grace, so the deadline below is only ever
            // reached once it has actually gone.
            deadline = now.advanced(by: Self.graceAfterOwnerLoss)
            return false
        }
        if everSeen, !reportedLoss {
            reportedLoss = true
            log.info("owning app exited; engine will stop unless it returns")
        }
        guard now >= deadline else { return false }
        expired = true
        return true
    }

    /// Wait until the app has been seen, or until the service has given up waiting.
    ///
    /// For startup work that only makes sense on behalf of an app — provisioning the persisted
    /// networks, say. An engine launchd demand-started for a CLI with no app running is about
    /// to exit, and a vmnet interface claimed on the way through outlives it as an orphan.
    ///
    /// - Returns: true if an app is there to work for, false if the service is leaving.
    public func waitUntilOwnedOrExpired() async -> Bool {
        // Reads state the poll loop maintains rather than driving its own, so the two cannot
        // disagree about when the grace ran out.
        while !everSeen, !expired {
            do {
                try await Task.sleep(for: poll)
            } catch {
                return false
            }
        }
        return everSeen && !expired
    }

    /// Poll until the app has been gone past the grace, then return so the caller can shut
    /// down. Never returns while the app is running.
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
