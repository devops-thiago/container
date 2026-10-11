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
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import TerminalProgress

extension Application {
    public struct BuildCommand: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "build"
            config.abstract = "Build an image from a Dockerfile or Containerfile"
            config._superCommandName = "container"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        enum ProgressType: String, ExpressibleByArgument {
            case auto
            case plain
            case tty
        }

        typealias SecretType = Builder.Secret

        @Option(
            name: .shortAndLong,
            help: ArgumentHelp("Add the architecture type to the build", valueName: "value"),
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var arch: [[String]] = {
            [[Arch.hostArchitecture().rawValue]]
        }()

        @Option(name: .long, help: ArgumentHelp("Set build-time variables", valueName: "key=val"))
        var buildArg: [String] = []

        @Option(name: .long, help: ArgumentHelp("Cache imports for the build", valueName: "value", visibility: .hidden))
        var cacheIn: [String] = {
            []
        }()

        @Option(name: .long, help: ArgumentHelp("Cache exports for the build", valueName: "value", visibility: .hidden))
        var cacheOut: [String] = {
            []
        }()

        @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the builder container")
        var cpus: Int64?

        @Option(name: .shortAndLong, help: ArgumentHelp("Path to Dockerfile", valueName: "path"))
        var file: String?

        var dockerfile: String = "-"

        @Option(name: .shortAndLong, help: ArgumentHelp("Set a label", valueName: "key=val"))
        var label: [String] = []

        @Option(
            name: .shortAndLong,
            help: "Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
        )
        var memory: String?

        @Flag(name: .long, help: "Do not use cache")
        var noCache: Bool = false

        @Option(name: .shortAndLong, help: ArgumentHelp("Output configuration for the build (format: type=<oci|tar|local>[,dest=])", valueName: "value"))
        var output: [String] = {
            ["type=oci"]
        }()

        @Option(
            name: .long,
            help: ArgumentHelp("Add the OS type to the build", valueName: "value"),
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var os: [[String]] = {
            [["linux"]]
        }()

        @Option(
            name: .long,
            help: "Add the platform to the build (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]",
            transform: { val in val.split(separator: ",").map { String($0) } }
        )
        var platform: [[String]] = [[]]

        @Option(name: .long, help: ArgumentHelp("Progress type (format: auto|plain|tty)", valueName: "type"))
        var progress: ProgressType = .auto

        @Flag(name: .shortAndLong, help: "Suppress build output")
        var quiet: Bool = false

        @Option(name: .long, help: ArgumentHelp("Set build-time secrets (format: id=<key>[,env=<ENV_VAR>|,src=<local/path>])", valueName: "id=key,..."))
        var secret: [String] = []

        var secrets: [String: SecretType] = [:]

        @Option(
            name: .long,
            help: ArgumentHelp("Forward SSH agent authentication to the build (format: default)", valueName: "default")
        )
        var ssh: String = ""

        @Option(name: [.short, .customLong("tag")], help: ArgumentHelp("Name for the built image", valueName: "name"))
        var targetImageNames: [String] = {
            [UUID().uuidString.lowercased()]
        }()

        @Option(name: .long, help: ArgumentHelp("Set the target build stage", valueName: "stage"))
        var target: String = ""

        @Option(name: .long, help: ArgumentHelp("Builder shim vsock port", valueName: "port"))
        var vsockPort: UInt32 = 8088

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup
        public var dns: Flags.DNS

        @Argument(help: "Build directory")
        var contextDir: String = "."

        @Flag(name: .long, help: "Pull latest image")
        var pull: Bool = false

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            let dockerfile = try await resolveBuildFile()
            // Absolute from here on, for the same reason `resolveBuildFile` makes it so: the
            // builder reads the context through this process, whose own `.` is not the user's.
            let contextDir = HostPath.absolute(self.contextDir)
            do {
                let timeout: Duration = .seconds(300)
                let progressConfig = try ProgressConfig(
                    showTasks: true,
                    showItems: true
                )
                let progress = ProgressBar(config: progressConfig)
                defer {
                    progress.finish()
                }
                progress.start()

                // Ensure the builder is started (or restarted) with the correct SSH configuration,
                // then dial it, starting it again until it answers or the timeout passes.
                let builder = try await Builder.connect(
                    Builder.StartOptions(
                        cpus: cpus,
                        memory: memory,
                        ssh: ssh == "default",
                        dnsNameservers: self.dns.nameservers
                    ),
                    vsockPort: vsockPort,
                    timeout: timeout,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    progressUpdate: progress.handler
                )

                let buildFileData: Data
                var ignoreFileData: Data? = nil
                // Dockerfile should be read from stdin
                if dockerfile == "-" {
                    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("Dockerfile-\(UUID().uuidString)")
                    defer {
                        try? FileManager.default.removeItem(at: tempFile)
                    }

                    guard FileManager.default.createFile(atPath: tempFile.path(), contents: nil) else {
                        throw ContainerizationError(.internalError, message: "unable to create temporary file")
                    }

                    guard let fileHandle = try? FileHandle(forWritingTo: tempFile) else {
                        throw ContainerizationError(.internalError, message: "unable to open temporary file for writing")
                    }

                    let bufferSize = 4096
                    while true {
                        let chunk = FileHandle.standardInput.readData(ofLength: bufferSize)
                        if chunk.isEmpty { break }
                        fileHandle.write(chunk)
                    }
                    try fileHandle.close()
                    buildFileData = try Data(contentsOf: URL(filePath: tempFile.path()))
                } else {
                    (buildFileData, ignoreFileData) = try Builder.readBuildFile(at: dockerfile)
                }

                try Builder.checkBuildFileSize(buildFileData)

                let secretsData = try Builder.readSecrets(self.secrets)

                let buildID = UUID().uuidString
                let tempURL = try await Builder.createExportDirectory(buildID: buildID)
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                let imageNames = try Builder.normalizedTags(targetImageNames)

                var terminal: Terminal?
                switch self.progress {
                case .tty:
                    terminal = try Terminal(descriptor: STDERR_FILENO)
                case .auto:
                    terminal = try? Terminal(descriptor: STDERR_FILENO)
                case .plain:
                    terminal = nil
                }

                defer { terminal?.tryReset() }

                let exports = try Builder.exports(from: output, exportDirectory: tempURL)

                try await withThrowingTaskGroup(of: Void.self) { [terminal] group in
                    defer {
                        group.cancelAll()
                    }
                    group.addTask {
                        let handler = AsyncSignalHandler.create(notify: [SIGTERM, SIGINT, SIGUSR1, SIGUSR2])
                        for await sig in handler.signals {
                            throw ContainerizationError(.interrupted, message: "exiting on signal \(sig)")
                        }
                    }
                    let platforms = try Builder.resolvePlatforms(
                        platforms: self.platform.flatMap { $0 },
                        os: self.os.flatMap { $0 },
                        arch: self.arch.flatMap { $0 },
                        log: log
                    )
                    group.addTask {
                        [
                            terminal, buildArg, secretsData, ssh, contextDir, ignoreFileData, label, noCache, target, quiet, cacheIn, cacheOut, pull, exports, imageNames, tempURL,
                            log
                        ] in
                        let config = Builder.BuildConfig(
                            buildID: buildID,
                            contentStore: RemoteContentStoreClient(),
                            buildArgs: buildArg,
                            secrets: secretsData,
                            ssh: ssh,
                            contextDir: contextDir,
                            dockerfile: buildFileData,
                            dockerignore: ignoreFileData,
                            labels: label,
                            noCache: noCache,
                            platforms: [Platform](platforms),
                            terminal: terminal,
                            tags: imageNames,
                            target: target,
                            quiet: quiet,
                            exports: exports,
                            cacheIn: cacheIn,
                            cacheOut: cacheOut,
                            pull: pull,
                            containerSystemConfig: containerSystemConfig,
                        )
                        progress.finish()

                        try await builder.build(config)

                        let unpackProgressConfig = try ProgressConfig(
                            description: "Unpacking built image",
                            itemsName: "entries",
                            showTasks: exports.count > 1,
                            totalTasks: exports.count
                        )
                        let unpackProgress = ProgressBar(config: unpackProgressConfig)
                        defer {
                            unpackProgress.finish()
                        }
                        unpackProgress.start()

                        let outcome = try await Builder.storeExports(
                            exports,
                            tags: imageNames,
                            exportDirectory: tempURL,
                            log: log,
                            progressUpdate: unpackProgress.handler
                        )
                        unpackProgress.finish()
                        print(outcome.summary)
                    }

                    try await group.next()
                }
            } catch {
                throw NSError(domain: "Build", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
            }
        }

        /// Borrow the build's folders when this process is sandboxed, then find the Dockerfile.
        private func resolveBuildFile() async throws -> String {
            do {
                return try await Builder.resolveBuildFile(
                    contextDir: contextDir,
                    file: file,
                    secretFiles: Builder.secretFiles(secrets),
                    log: log
                )
            } catch let error as BuildInputError {
                throw ValidationError(error.message)
            }
        }

        public mutating func validate() throws {
            for name in targetImageNames {
                guard let _ = try? Reference.parse(name) else {
                    throw ValidationError("invalid reference \(name)")
                }
            }
            // The Dockerfile is found in `run`, after this process has been lent the folder it
            // sits in: validation runs before anything can be borrowed, and a sandboxed CLI
            // cannot tell "no Dockerfile" from "not allowed to look" until then.
            if file == "-" { dockerfile = "-" }

            // Parse --secret args
            for secret in self.secret {
                let parts = secret.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts[0].hasPrefix("id=") else {
                    throw ValidationError("secret must start with id=<key> \(secret)")
                }
                let key = String(parts[0].dropFirst(3))
                guard !key.contains("=") else {
                    throw ValidationError("secret id cannot contain '=' \(key)")
                }
                if parts.count == 1 || parts[1].hasPrefix("env=") {
                    let env = parts.count == 1 ? key : String(parts[1].dropFirst(4))
                    // Using getenv/strlen over processInfo.environment to support
                    // non-UTF-8 env var data.
                    guard let ptr = getenv(env) else {
                        throw ValidationError("secret env var doesn't exist \(env)")
                    }
                    self.secrets[key] = .data(Data(bytes: ptr, count: strlen(ptr)))
                } else if parts[1].hasPrefix("src=") {
                    let path = HostPath.absolute(String(parts[1].dropFirst(4)))
                    self.secrets[key] = .file(path)
                } else {
                    throw ValidationError("secret bad value \(parts[1])")
                }
            }

            switch ssh {
            case "":
                break
            case "default" where ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil:
                break
            case "default":
                throw ValidationError("--ssh default requires SSH_AUTH_SOCK to be set")
            default:
                throw ValidationError("only --ssh default is currently supported")
            }
        }
    }
}
