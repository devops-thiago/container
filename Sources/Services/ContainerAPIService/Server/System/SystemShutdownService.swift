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
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

private enum ShutdownContainerListState: Sendable {
    case pending
    case success([ContainerSnapshot])
    case failure(String)
}

private actor ShutdownContainerListResult {
    private var state: ShutdownContainerListState = .pending

    func complete(_ state: ShutdownContainerListState) {
        guard case .pending = self.state else { return }
        self.state = state
    }

    func value() -> ShutdownContainerListState {
        state
    }
}

private actor ShutdownCompletionCounter {
    private var completed = 0

    func finish() {
        completed += 1
    }

    func value() -> Int {
        completed
    }
}

public actor SystemShutdownService {
    private static let apiServerLabel = ServiceIdentity.apiServerService
    private static let launchdLabelPrefix = ServiceIdentity.machPrefix
    private static let stopTimeoutSeconds: Int32 = 5
    private static let shutdownTimeoutSeconds = 20
    private static let launchctlCommandTimeout: TimeInterval = 2

    private let lifecycleGeneration: String
    private let processNonce: String
    private let appRoot: URL
    private let ownershipToken: String?
    private let containersService: ContainersService
    private let pluginsService: PluginsService
    private let shutdownGate: SystemShutdownGate
    private let log: Logger
    private var shutdownStarted = false

    public init(
        lifecycleGeneration: String,
        processNonce: String,
        appRoot: URL,
        ownershipToken: String?,
        containersService: ContainersService,
        pluginsService: PluginsService,
        shutdownGate: SystemShutdownGate,
        log: Logger
    ) {
        self.lifecycleGeneration = lifecycleGeneration
        self.processNonce = processNonce
        self.appRoot = appRoot
        self.ownershipToken = ownershipToken
        self.containersService = containersService
        self.pluginsService = pluginsService
        self.shutdownGate = shutdownGate
        self.log = log
    }

    @Sendable
    public func shutdown(_ message: XPCMessage, session: XPCServerSession) async throws -> XPCMessage {
        guard let expectedGeneration = message.string(key: .expectedLifecycleGeneration),
            expectedGeneration == lifecycleGeneration
        else {
            throw ContainerizationError(.invalidState, message: "lifecycle generation does not match this API server")
        }
        guard let expectedNonce = message.string(key: .expectedProcessNonce),
            expectedNonce == processNonce
        else {
            throw ContainerizationError(.invalidState, message: "process nonce does not match this API server")
        }

        let confirmedTakeover = message.bool(key: .confirmedTakeover)
        if !confirmedTakeover {
            guard let requestToken = message.string(key: .ownershipToken),
                let ownershipToken,
                requestToken == ownershipToken
            else {
                throw ContainerizationError(.invalidState, message: "shutdown ownership token does not match")
            }
        }

        guard !shutdownStarted else {
            throw ContainerizationError(.invalidState, message: "API server shutdown is already in progress")
        }

        let tombstone = try APIServerShutdownTombstone.currentProcess(
            lifecycleGeneration: lifecycleGeneration,
            processNonce: processNonce
        )
        do {
            try APIServerShutdownTombstoneStore.commit(tombstone, appRoot: appRoot)
        } catch let error as APIServerShutdownTombstoneStore.CommitError {
            log.critical(
                "shutdown tombstone commit outcome is indeterminate; exiting without acknowledgement",
                metadata: ["error": "\(error)"]
            )
            Darwin.exit(EXIT_FAILURE)
        } catch {
            throw error
        }

        let apiServerJobLabel = PluginLoader.generationQualifiedLabel(
            Self.apiServerLabel,
            lifecycleGeneration: lifecycleGeneration
        )
        shutdownStarted = true

        // The acknowledgement must be delivered before launchd terminates this daemon.
        // Register this before any cleanup, and keep it as the only API-server bootout site.
        let log = self.log
        let launchctlTimeout = Self.launchctlCommandTimeout
        await session.onDisconnect {
            var lastError: (any Error)?
            for attempt in 1...3 {
                do {
                    let domain = try ServiceManager.getDomainString(timeout: launchctlTimeout)
                    let fullLabel = "\(domain)/\(apiServerJobLabel)"
                    log.info(
                        "stopping API server",
                        metadata: ["label": "\(fullLabel)", "attempt": "\(attempt)"])
                    try ServiceManager.deregister(
                        fullServiceLabel: fullLabel,
                        timeout: launchctlTimeout)
                    return
                } catch {
                    lastError = error
                    if attempt < 3 { usleep(100_000) }
                }
            }

            // Cleanup has permanently quiesced mutation admission and torn down workloads.
            // A live process after failed bootout cannot safely resume, and would reject both
            // mutations and repeated shutdown forever. Exit with the durable tombstone retained;
            // if launchd demand-starts this generation again, startup will refuse to serve.
            log.critical(
                "failed to stop API server after retries; exiting",
                metadata: [
                    "label": "\(apiServerJobLabel)",
                    "error": "\(String(describing: lastError))",
                ]
            )
            Darwin.exit(EXIT_FAILURE)
        }

        let clock = ContinuousClock()
        let cleanupDeadline = clock.now.advanced(by: .seconds(Self.shutdownTimeoutSeconds))
        if await !shutdownGate.quiesce(until: cleanupDeadline) {
            log.warning("timed out waiting for active API mutations during shutdown")
        }
        await stopContainers(until: cleanupDeadline)
        await stopPlugins(until: cleanupDeadline)
        await sweepGenerationJobs(excluding: apiServerJobLabel, until: cleanupDeadline)

        let reply = message.reply()
        reply.set(key: .acknowledged, value: true)
        return reply
    }

    private func stopContainers(until deadline: ContinuousClock.Instant) async {
        guard let snapshots = await listContainers(until: deadline) else {
            return
        }

        let completions = ShutdownCompletionCounter()
        let service = containersService
        let log = self.log
        let options = ContainerStopOptions(timeoutInSeconds: Self.stopTimeoutSeconds, signal: nil)
        for snapshot in snapshots {
            guard let responseTimeout = Self.remainingDuration(until: deadline) else {
                log.warning("container cleanup deadline expired")
                return
            }
            Task {
                do {
                    try await service.stop(
                        id: snapshot.id,
                        options: options,
                        responseTimeout: responseTimeout
                    )
                } catch {
                    log.error(
                        "failed to stop container during shutdown",
                        metadata: [
                            "id": "\(snapshot.id)",
                            "error": "\(error)",
                        ]
                    )
                }
                await completions.finish()
            }
        }

        while await completions.value() < snapshots.count {
            guard let remaining = Self.remainingDuration(until: deadline) else {
                log.warning("timed out stopping containers during shutdown")
                return
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(100)))
            } catch {
                log.warning("container shutdown wait was cancelled")
                return
            }
        }
    }

    private func listContainers(until deadline: ContinuousClock.Instant) async -> [ContainerSnapshot]? {
        let result = ShutdownContainerListResult()
        let service = containersService
        Task {
            do {
                await result.complete(.success(try await service.list()))
            } catch {
                await result.complete(.failure(String(describing: error)))
            }
        }

        while true {
            switch await result.value() {
            case .pending:
                guard let remaining = Self.remainingDuration(until: deadline) else {
                    log.warning("timed out listing containers during shutdown")
                    return nil
                }
                do {
                    try await Task.sleep(for: min(remaining, .milliseconds(100)))
                } catch {
                    log.warning("container list wait was cancelled during shutdown")
                    return nil
                }
            case .success(let snapshots):
                return snapshots
            case .failure(let error):
                log.error("failed to list containers during shutdown", metadata: ["error": "\(error)"])
                return nil
            }
        }
    }

    private func stopPlugins(until deadline: ContinuousClock.Instant) async {
        let completion = ShutdownCompletionCounter()
        let service = pluginsService
        Task {
            await service.stopAllBestEffort(until: deadline)
            await completion.finish()
        }

        while await completion.value() == 0 {
            guard let remaining = Self.remainingDuration(until: deadline) else {
                log.warning("timed out stopping plugins during shutdown")
                return
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(100)))
            } catch {
                log.warning("plugin shutdown wait was cancelled")
                return
            }
        }
    }

    private func sweepGenerationJobs(
        excluding apiServerJobLabel: String,
        until deadline: ContinuousClock.Instant
    ) async {
        let completion = ShutdownCompletionCounter()
        let lifecycleGeneration = self.lifecycleGeneration
        let log = self.log
        Task.detached {
            Self.performGenerationSweep(
                lifecycleGeneration: lifecycleGeneration,
                excluding: apiServerJobLabel,
                until: deadline,
                log: log
            )
            await completion.finish()
        }

        while await completion.value() == 0 {
            guard let remaining = Self.remainingDuration(until: deadline) else {
                log.warning("timed out sweeping generation launchd jobs during shutdown")
                return
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(100)))
            } catch {
                log.warning("generation launchd sweep wait was cancelled")
                return
            }
        }
    }

    private nonisolated static func performGenerationSweep(
        lifecycleGeneration: String,
        excluding apiServerJobLabel: String,
        until deadline: ContinuousClock.Instant,
        log: Logger
    ) {
        let domain: String
        do {
            guard let timeout = launchctlTimeout(until: deadline) else {
                log.warning("generation cleanup deadline expired before domain lookup")
                return
            }
            domain = try ServiceManager.getDomainString(timeout: timeout)
        } catch {
            log.error("failed to resolve launchd domain during shutdown", metadata: ["error": "\(error)"])
            return
        }

        let labels: [String]
        do {
            guard let timeout = launchctlTimeout(until: deadline) else {
                log.warning("generation cleanup deadline expired before launchd enumeration")
                return
            }
            labels = try ServiceManager.enumerate(timeout: timeout)
        } catch {
            log.error("failed to enumerate launchd jobs during shutdown", metadata: ["error": "\(error)"])
            return
        }

        let suffix = ".\(lifecycleGeneration)"
        for label in labels
        where label.hasPrefix(launchdLabelPrefix)
            && label.hasSuffix(suffix)
            && label != apiServerJobLabel
        {
            guard let timeout = launchctlTimeout(until: deadline) else {
                log.warning("generation cleanup deadline expired while sweeping launchd jobs")
                return
            }
            let fullLabel = "\(domain)/\(label)"
            do {
                try ServiceManager.deregister(fullServiceLabel: fullLabel, timeout: timeout)
            } catch {
                log.error(
                    "failed to sweep launchd job during shutdown",
                    metadata: [
                        "label": "\(fullLabel)",
                        "error": "\(error)",
                    ]
                )
            }
        }
    }

    private nonisolated static func remainingDuration(
        until deadline: ContinuousClock.Instant
    ) -> Duration? {
        let remaining = ContinuousClock().now.duration(to: deadline)
        return remaining > .zero ? remaining : nil
    }

    private nonisolated static func launchctlTimeout(
        until deadline: ContinuousClock.Instant
    ) -> TimeInterval? {
        guard let remaining = remainingDuration(until: deadline) else { return nil }
        let components = remaining.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return min(launchctlCommandTimeout, max(0.001, seconds))
    }
}
