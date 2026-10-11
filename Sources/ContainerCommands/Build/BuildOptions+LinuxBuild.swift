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
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerLog
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIO
import TerminalProgress

extension BuildOptions {
    /// Resolves the set of target platforms from `--platform`, the
    /// `CONTAINER_DEFAULT_PLATFORM` environment variable, and `--os`/`--arch`.
    public func resolvePlatforms() throws -> Set<Platform> {
        try Builder.resolvePlatforms(
            platforms: self.platform.flatMap { $0 },
            os: self.os.flatMap { $0 },
            arch: self.arch.flatMap { $0 },
            log: log
        )
    }

    /// Runs the Linux build using the builder container.
    public func runLinuxBuild(containerSystemConfig: ContainerSystemConfig) async throws {
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

            let imageNames = try Builder.normalizedTags(targetImageNames, containerSystemConfig: containerSystemConfig)

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
    func resolveBuildFile() async throws -> String {
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
}
