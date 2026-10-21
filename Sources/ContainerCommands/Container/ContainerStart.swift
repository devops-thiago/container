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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import SystemPackage
import TerminalProgress

extension Application {
    public struct ContainerStart: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start a container")

        @Flag(name: .shortAndLong, help: "Attach stdout/stderr")
        var attach = false

        @Flag(name: .shortAndLong, help: "Attach stdin")
        var interactive = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        /// Whether this start gives `container`'s process the host terminal's raw keys: it
        /// attaches stdin to a process with a terminal that is not running yet.
        func usesRawTerminal(_ container: ContainerSnapshot) -> Bool {
            interactive && container.configuration.initProcess.terminal && container.status != .running
        }

        /// A direct invocation can lack the launcher's raw terminal setup. That alone does
        /// not establish an outdated launcher. Current launchers refuse unavailable probes
        /// before executing start rather than allowing that failure to reach this path.
        static let lineModeMeansOutdatedLauncher = false

        public func run() async throws {
            var exitCode: Int32 = 127

            let progressConfig = try ProgressConfig(
                description: "Starting container"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            let detach = !self.attach && !self.interactive
            let client = ContainerClient()
            let container = try await client.get(id: containerId)

            // Bootstrap and process start are both idempotent and don't fail the second time
            // around, however not doing an rpc is always faster :). The other bit is we don't
            // support attach currently, so we can't do `start -a` a second time and have it succeed.
            if container.status == .running {
                if !detach {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "attach is currently unsupported on already running containers"
                    )
                }
                print(containerId)
                return
            }

            for mount in container.configuration.mounts where mount.isVirtiofs {
                if !FileManager.default.fileExists(atPath: mount.source) {
                    // The engine's Docker API socket is there only while its agent serves it;
                    // the engine binds it for the host's, and refuses the start, naming the
                    // setting, when nothing answers.
                    if try await Self.isDockerSocket(mount.source) {
                        throw ContainerizationError(.invalidArgument, message: DockerHostSocket.notServedMessage)
                    }
                    throw ContainerizationError(.invalidState, message: "mount source path '\(mount.source)' does not exist")
                }
            }

            do {
                let io = try ProcessIO.create(
                    tty: container.configuration.initProcess.terminal,
                    interactive: self.interactive,
                    detach: detach,
                    launcherSetsRaw: Self.lineModeMeansOutdatedLauncher
                )
                defer {
                    try? io.close()
                }

                var env: [String: String] = [:]
                if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                    env["SSH_AUTH_SOCK"] = sshAuthSock
                }

                let process = try await client.bootstrap(id: container.id, stdio: io.stdio, dynamicEnv: env)
                progress.finish()

                if detach {
                    try await process.start()
                    try io.closeAfterStart()
                    print(self.containerId)
                    return
                }

                exitCode = try await io.handleProcess(process: process, log: log)
            } catch {
                try? await client.stop(id: container.id)

                if error is ContainerizationError {
                    throw error
                }
                throw ContainerizationError(.internalError, message: "failed to start container: \(error)")
            }
            throw ArgumentParser.ExitCode(exitCode)
        }
    }

}

extension Application.ContainerStart {
    /// Whether `source` is the host's Docker socket or the engine's own, which a start binds
    /// for it.
    static func isDockerSocket(_ source: String) async throws -> Bool {
        if DockerHostSocket.names(source) { return true }
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        return source == PathUtils.dockerSocketPath(engineAppRoot: FilePath(health.appRoot.path(percentEncoded: false)))
    }
}
