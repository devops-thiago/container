//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import Logging

extension Application {
    public struct SystemStop: AsyncLoggableCommand {
        private static let stopTimeoutSeconds: Int32 = 5
        private static let shutdownTimeoutSeconds: Int32 = 20
        private static let launchctlCommandTimeout: TimeInterval = 2
        private static let apiServerService = ServiceIdentity.apiServerService
        private static let ownershipTokenEnvironmentName = "CONTAINER_SILICONSHIP_OWNERSHIP_TOKEN"

        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop all `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = ServiceIdentity.machPrefix

        @Option(name: .long, help: "Expected API-server PID")
        var expectedPID: Int32?

        @Option(name: .long, help: "Expected API-server process birth time seconds")
        var expectedStartSeconds: UInt64?

        @Option(name: .long, help: "Expected API-server process birth time microseconds")
        var expectedStartMicroseconds: UInt64?

        @Option(name: .long, help: "Expected API-server lifecycle generation")
        var expectedLifecycleGeneration: String?

        @Option(name: .long, help: "Expected API-server process nonce")
        var expectedProcessNonce: String?

        @Flag(name: .long, help: "Confirm takeover and bypass ownership-token validation")
        var confirmedTakeover = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func validate() throws {
            let expectedValues: [Any?] = [
                expectedPID,
                expectedStartSeconds,
                expectedStartMicroseconds,
                expectedLifecycleGeneration,
                expectedProcessNonce,
            ]
            let suppliedCount = expectedValues.compactMap { $0 }.count
            if confirmedTakeover, suppliedCount != expectedValues.count {
                throw ValidationError("--confirmed-takeover requires a complete expected-instance identity")
            }
            guard suppliedCount == 0 || suppliedCount == expectedValues.count else {
                throw ValidationError(
                    "Expected-instance shutdown requires --expected-pid, --expected-start-seconds, "
                        + "--expected-start-microseconds, --expected-lifecycle-generation, and --expected-process-nonce"
                )
            }
            if let expectedLifecycleGeneration,
                !PluginLoader.isValidLifecycleGeneration(expectedLifecycleGeneration)
            {
                throw ValidationError("Expected lifecycle generation must contain only ASCII letters, digits, and hyphens")
            }
            if let expectedPID, expectedPID <= 0 {
                throw ValidationError("Expected PID must be greater than zero")
            }
            if let expectedProcessNonce, expectedProcessNonce.isEmpty {
                throw ValidationError("Expected process nonce must be nonempty")
            }
        }

        public func run() async throws {
            // Same reasoning as `system start`: the host app owns the engine's lifetime,
            // and stopping it from here would ask launchctl to bootout an SMAppService job
            // the app is holding open. Say what to do instead.
            if ServiceIdentity.isEmbedded {
                throw ContainerizationError(
                    .unsupported,
                    message: """
                        this engine is embedded in an app, which starts and stops it. \
                        Quit the app to stop the engine.
                        """)
            }
            let log = Logger(
                label: ServiceIdentity.machPrefix + "cli",
                factory: { label in
                    StreamLogHandler.standardOutput(label: label)
                }
            )

            if let expectedPID,
                let expectedStartSeconds,
                let expectedStartMicroseconds,
                let expectedLifecycleGeneration,
                let expectedProcessNonce
            {
                try await stopExpectedInstance(
                    expectedPID: expectedPID,
                    expectedStartSeconds: expectedStartSeconds,
                    expectedStartMicroseconds: expectedStartMicroseconds,
                    expectedLifecycleGeneration: expectedLifecycleGeneration,
                    expectedProcessNonce: expectedProcessNonce,
                    log: log
                )
                return
            }

            try await stopLegacy(log: log)
        }

        private func stopExpectedInstance(
            expectedPID: Int32,
            expectedStartSeconds: UInt64,
            expectedStartMicroseconds: UInt64,
            expectedLifecycleGeneration: String,
            expectedProcessNonce: String,
            log: Logger
        ) async throws {
            let client = XPCClient(service: Self.apiServerService)
            let session = client.openSession()
            let expectedTombstone = APIServerShutdownTombstone(
                lifecycleGeneration: expectedLifecycleGeneration,
                processNonce: expectedProcessNonce,
                pid: expectedPID,
                processStartSeconds: expectedStartSeconds,
                processStartMicroseconds: expectedStartMicroseconds
            )
            let appRoot: URL

            do {
                let health = try await ClientHealthCheck.ping(session: session, timeout: .seconds(5))
                guard health.lifecycleProtocolVersion == SystemHealth.currentLifecycleProtocolVersion else {
                    throw ContainerizationError(.invalidState, message: "API server does not support lifecycle protocol version 1")
                }
                guard health.lifecycleGeneration == expectedLifecycleGeneration else {
                    throw ContainerizationError(.invalidState, message: "API-server lifecycle generation does not match")
                }
                guard health.processNonce == expectedProcessNonce else {
                    throw ContainerizationError(.invalidState, message: "API-server process nonce does not match")
                }

                let remotePID = session.remotePid()
                guard remotePID == expectedPID else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "API-server PID does not match (expected \(expectedPID), got \(remotePID))"
                    )
                }
                try verifyProcessBirth(
                    pid: remotePID,
                    expectedSeconds: expectedStartSeconds,
                    expectedMicroseconds: expectedStartMicroseconds
                )
                appRoot = health.appRoot

                log.info(
                    "requesting generation-aware API-server shutdown",
                    metadata: [
                        "generation": "\(expectedLifecycleGeneration)",
                        "pid": "\(expectedPID)",
                    ]
                )
                try await SystemShutdownClient.shutdown(
                    session: session,
                    expectedLifecycleGeneration: expectedLifecycleGeneration,
                    expectedProcessNonce: expectedProcessNonce,
                    ownershipToken: ProcessInfo.processInfo.environment[Self.ownershipTokenEnvironmentName],
                    confirmedTakeover: confirmedTakeover,
                    timeout: .seconds(60)
                )

                guard
                    let committedTombstone = try APIServerShutdownTombstoneStore.load(
                        appRoot: appRoot,
                        lifecycleGeneration: expectedLifecycleGeneration
                    )
                else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "API-server shutdown was acknowledged without a committed shutdown tombstone"
                    )
                }
                guard committedTombstone == expectedTombstone else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "committed API-server shutdown tombstone does not match the expected process identity"
                    )
                }
            } catch {
                session.close()
                throw error
            }

            session.close()

            let tombstoneURL = try APIServerShutdownTombstoneStore.tombstoneURL(
                appRoot: appRoot,
                lifecycleGeneration: expectedLifecycleGeneration
            )
            let clock = ContinuousClock()
            let disappearanceDeadline = clock.now.advanced(
                by: .seconds(Int64(Self.shutdownTimeoutSeconds))
            )
            let jobLabel = PluginLoader.generationQualifiedLabel(
                Self.apiServerService,
                lifecycleGeneration: expectedLifecycleGeneration
            )
            var fullLabel: String?
            var attempt = 0
            var lastError: (any Error)?
            while let operationTimeout = Self.launchctlTimeout(until: disappearanceDeadline) {
                if fullLabel == nil {
                    do {
                        let domain = try ServiceManager.getDomainString(timeout: operationTimeout)
                        fullLabel = "\(domain)/\(jobLabel)"
                    } catch {
                        lastError = error
                        guard let remaining = Self.remainingDuration(until: disappearanceDeadline) else {
                            break
                        }
                        do {
                            try await Task.sleep(for: min(remaining, .milliseconds(100)))
                        } catch {
                            lastError = error
                            break
                        }
                        continue
                    }
                }
                guard let fullLabel else { continue }

                do {
                    if try !ServiceManager.isRegistered(
                        fullServiceLabel: jobLabel,
                        timeout: operationTimeout
                    ) {
                        return
                    }
                } catch {
                    lastError = error
                }

                guard let bootoutTimeout = Self.launchctlTimeout(until: disappearanceDeadline) else {
                    break
                }
                attempt += 1
                do {
                    log.info(
                        "requesting caller-side API-server bootout",
                        metadata: [
                            "label": "\(fullLabel)",
                            "attempt": "\(attempt)",
                        ]
                    )
                    try ServiceManager.deregister(
                        fullServiceLabel: fullLabel,
                        timeout: bootoutTimeout
                    )
                } catch {
                    lastError = error
                }

                guard let remaining = Self.remainingDuration(until: disappearanceDeadline) else {
                    break
                }
                do {
                    try await Task.sleep(for: min(remaining, .milliseconds(100)))
                } catch {
                    lastError = error
                    break
                }
            }

            let cleanupLabel = fullLabel ?? jobLabel
            let detail = lastError.map { ": \($0)" } ?? ""
            throw ContainerizationError(
                .invalidState,
                message: "API-server shutdown committed, but launchd registration cleanup failed for \(cleanupLabel); "
                    + "shutdown tombstone retained at \(tombstoneURL.path)\(detail)"
            )
        }

        private static func remainingDuration(
            until deadline: ContinuousClock.Instant
        ) -> Duration? {
            let remaining = ContinuousClock().now.duration(to: deadline)
            return remaining > .zero ? remaining : nil
        }

        private static func launchctlTimeout(
            until deadline: ContinuousClock.Instant
        ) -> TimeInterval? {
            guard let remaining = remainingDuration(until: deadline) else { return nil }
            let components = remaining.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            return min(launchctlCommandTimeout, max(0.001, seconds))
        }

        private func verifyProcessBirth(
            pid: pid_t,
            expectedSeconds: UInt64,
            expectedMicroseconds: UInt64
        ) throws {
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
            guard actualSize == expectedSize else {
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to read API-server process birth time for PID \(pid)"
                )
            }
            guard info.pbi_start_tvsec == expectedSeconds,
                info.pbi_start_tvusec == expectedMicroseconds
            else {
                throw ContainerizationError(.invalidState, message: "API-server process birth time does not match")
            }
        }

        private func stopLegacy(log: Logger) async throws {
            let launchdDomainString = try ServiceManager.getDomainString()
            let fullLabel = "\(launchdDomainString)/\(prefix)apiserver"

            var running = true
            do {
                log.info("checking if APIServer is alive")
                _ = try await ClientHealthCheck.ping(timeout: .seconds(5))
            } catch {
                log.info("APIServer health check failed, skipping bootout")
                running = false
            }

            if running {
                let client = ContainerClient()
                log.info("stopping containers", metadata: ["stopTimeoutSeconds": "\(Self.stopTimeoutSeconds)"])
                do {
                    let containers = try await client.list().map { $0.id }
                    let opts = ContainerStopOptions(timeoutInSeconds: Self.stopTimeoutSeconds, signal: nil)
                    try await ContainerStop.stopContainers(
                        client: client,
                        containers: containers,
                        stopOptions: opts,
                    )
                } catch {
                    log.warning("failed to stop all containers", metadata: ["error": "\(error)"])
                }

                log.info("waiting for containers to exit")
                do {
                    for _ in 0..<Self.shutdownTimeoutSeconds {
                        let runningContainers = try await client.list(filters: ContainerListFilters(status: .running))
                        guard !runningContainers.isEmpty else {
                            break
                        }
                        try await Task.sleep(for: .seconds(1))
                    }

                    log.info("stopping service", metadata: ["label": "\(fullLabel)"])
                    try ServiceManager.deregister(fullServiceLabel: fullLabel)
                } catch {
                    log.warning("failed to wait for all containers", metadata: ["error": "\(error)"])
                }
            }

            // Keep the unqualified stop behavior unchanged for backward compatibility.
            try ServiceManager.enumerate()
                .filter { $0.hasPrefix(prefix) }
                .filter { $0 != fullLabel }
                .map { "\(launchdDomainString)/\($0)" }
                .forEach {
                    log.info("stopping service", metadata: ["label": "\($0)"])
                    try? ServiceManager.deregister(fullServiceLabel: $0)
                }
        }
    }
}
