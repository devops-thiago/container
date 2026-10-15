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
import ContainerLog
import ContainerPersistence
import ContainerPlugin
import DockerAPIService
import Foundation
import Logging
import NIOCore
import NIOPosix
import SystemPackage

extension DockerAPIAgent {
    struct Start: AsyncParsableCommand {
        private static let commandName = "container-docker-api"
        private static let logFile = FilePath.Component("container-docker-api.log")

        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Serve the Docker Engine API"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        /// The socket's directory. Defaults to the engine's run directory.
        @Option(help: "Directory to create the socket in")
        var runDirectory: String?

        var logRoot = LogRoot.path

        func run() async throws {
            let debug = debug || (ProcessInfo.processInfo.environment["CONTAINER_DEBUG"] != nil)
            let logPath = logRoot.map { $0.appending(Self.logFile) }
            let log = ServiceLogger.bootstrap(category: "DockerAPI", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(Self.commandName)"])

            // Exits: 0 when there is nothing to serve (no app, or a path the CLI cannot dial)
            // and nothing launchd should retry; nonzero only for a failure a restart can fix.
            // The launchd job restarts only an unsuccessful exit.
            let directory: URL
            do {
                directory = try runDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PathUtils.runDirectory()
            } catch {
                log.error("no run directory", metadata: ["error": "\(error)"])
                DockerAPIAgent.exit(withError: error)
            }
            let socket = directory.appending(path: DockerSocketPlacement.socketName).path(percentEncoded: false)
            let statusFile = directory.appending(path: DockerAPIStatus.fileName)

            guard DockerSocketPlacement.fits(socket) else {
                // The CLI could not dial it, so serving it would only look like it works. Say
                // why where the app reads, and stop for good.
                log.error(
                    "socket path is longer than the Docker CLI accepts",
                    metadata: ["path": "\(socket)", "bytes": "\(socket.utf8.count)", "max": "\(DockerSocketPlacement.maxPathBytes)"])
                try? DockerAPIStatus(state: .pathTooLong, socketPath: socket).write(to: statusFile)
                Foundation.exit(0)
            }

            switch DockerSocketPlacement.inspect(socket) {
            case .nothing:
                break
            case .staleSocket:
                log.info("removing a stale socket", metadata: ["path": "\(socket)"])
                unlink(socket)
            case .liveSocket:
                log.error("another agent is serving the socket", metadata: ["path": "\(socket)"])
                DockerAPIAgent.exit(withError: ValidationError("\(socket) is already being served"))
            case .notASocket:
                log.error("something other than a socket is at the socket path", metadata: ["path": "\(socket)"])
                DockerAPIAgent.exit(withError: ValidationError("\(socket) exists and is not a socket"))
            }

            let watchdog = OwnerWatchdog(log: log)
            var router = DockerRouter(log: log)
            router.gate = {
                await watchdog.isOwned()
                    ? nil : DockerAPIError(.serviceUnavailable, "SiliconShip is not running. Open SiliconShip to use the Docker CLI.")
            }
            SystemRoutes.register(on: &router, engine: EngineSystemClient())
            let service = DockerAPIServer(router: router, log: log)
            let uid = getuid()

            let server: any Channel
            do {
                server = try await DockerAPIServer.configure(ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton))
                    .serverChannelOption(.backlog, value: 64)
                    .childChannelInitializer { service.initialize($0, allowedUID: uid) }
                    .bind(unixDomainSocketPath: socket)
                    .get()
                // Only this user: the directory is 0700 already, this holds even if it is not.
                guard chmod(socket, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try DockerAPIStatus(state: .listening, socketPath: socket).write(to: statusFile)
            } catch {
                log.error("could not serve the socket", metadata: ["path": "\(socket)", "error": "\(error)"])
                unlink(socket)
                try? FileManager.default.removeItem(at: statusFile)
                DockerAPIAgent.exit(withError: error)
            }
            log.info("serving the Docker Engine API", metadata: ["path": "\(socket)"])

            // Every way of stopping on purpose leaves nothing behind: the socket and the status
            // file go, so a client sees "no such file" rather than a socket nobody answers.
            let cleanup: @Sendable () -> Void = {
                unlink(socket)
                try? FileManager.default.removeItem(at: statusFile)
            }
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    log.info("stopping on a signal", metadata: ["signal": "\(number)"])
                    cleanup()
                    Foundation.exit(0)
                }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }

            let ownerWatch = Task {
                await watchdog.waitForOwnerLoss()
                log.info("docker api helper has no owning app; stopping")
                cleanup()
                Foundation.exit(0)
            }
            defer { ownerWatch.cancel() }

            // The listener only closes on its own if something went wrong, which a restart may fix.
            do {
                try await server.closeFuture.get()
            } catch {
                log.error("server stopped", metadata: ["error": "\(error)"])
            }
            cleanup()
            DockerAPIAgent.exit(withError: ValidationError("the Docker API listener closed"))
        }
    }
}
