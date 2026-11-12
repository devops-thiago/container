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

import ArgumentParser
import ClusterHostStoreService
import ContainerCluster
import ContainerLog
import ContainerPersistence
import ContainerPlugin
import ContainerVersion
import Foundation
import SystemPackage

@main
struct ClusterHostStore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cluster-hoststore",
        abstract: "Serves host images to container cluster nodes",
        version: ReleaseVersion.singleLine(appName: "cluster-hoststore"),
        subcommands: [Start.self],
    )
}

extension ClusterHostStore {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start the host store server"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        var logRoot = LogRoot.path

        func run() async throws {
            let debug = debug || (ProcessInfo.processInfo.environment["CONTAINER_DEBUG"] != nil)
            let logPath = logRoot.map { $0.appending("cluster-hoststore.log") }
            let log = ServiceLogger.bootstrap(category: "ClusterHostStore", debug: debug, logPath: logPath)

            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let socketPath = ClusterHelper.hostStoreSocketPath.string
            // Exits 0 when there is nothing to serve, which launchd does not retry; nonzero
            // only for a failure a restart can fix.
            do {
                _ = try PathUtils.runDirectory()
            } catch {
                log.error("no run directory", metadata: ["error": "\(error)"])
                ClusterHostStore.exit(withError: error)
            }
            guard ClusterHelper.socketPathFits(socketPath) else {
                // Neither this bind nor the node relay's dial could take it, so stop for good.
                log.error(
                    "socket path is longer than a socket address holds",
                    metadata: [
                        "path": "\(socketPath)", "bytes": "\(socketPath.utf8.count)", "max": "\(ClusterHelper.maxSocketPathBytes)",
                    ])
                Foundation.exit(0)
            }
            // Held from here until the process ends: it is how the app tells a store that is
            // busy from one that is gone. Another store still holding it is on its way out,
            // or is the one serving; either way this one does not take the socket from it.
            let lockPath = HostStoreLiveness.lockPath(socketPath: socketPath)
            do {
                guard try HostStoreLiveness.hold(lockPath: lockPath) != nil else {
                    log.error("another host store holds the lock", metadata: ["lock": "\(lockPath)"])
                    Foundation.exit(1)
                }
            } catch {
                // Serving without the lock is what every store before this one did.
                log.error("failed to take the host store lock", metadata: ["lock": "\(lockPath)", "error": "\(error)"])
            }
            let server = HostStoreServer(containerSystemConfig: containerSystemConfig, log: log)
            log.info("serving host store", metadata: ["socket": "\(socketPath)"])
            // Stop with the app that owns the engine, as every other engine service does.
            let ownerWatchdog = OwnerWatchdog(log: log)
            let ownerWatch = Task {
                await ownerWatchdog.waitForOwnerLoss()
                log.info("host store has no owning app; stopping")
                Darwin.exit(0)
            }
            defer { ownerWatch.cancel() }
            do {
                try await server.run(socketPath: socketPath)
            } catch {
                log.error("host store failed", metadata: ["error": "\(error)"])
                ClusterHostStore.exit(withError: error)
            }
        }
    }
}
