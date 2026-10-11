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
import ContainerImagesServiceClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import TerminalProgress

/// A build input that cannot be used: a folder that could not be borrowed, a missing
/// context or Dockerfile, an invalid platform. `description` is the message to show.
public struct BuildInputError: Swift.Error, CustomStringConvertible, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

extension Builder {
    // MARK: - Context

    /// The folders this process must be able to read for the build: the context, and the
    /// Dockerfile's folder when `file` points outside it. Absolute, so a lend names what the
    /// user will recognise in a panel.
    public static func foldersToBorrow(
        contextDir: String, file: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let context = HostPath.absolute(contextDir, environment: environment)
        var folders = [context]
        if let file, file != "-" {
            let parent = URL(fileURLWithPath: HostPath.absolute(file, environment: environment)).deletingLastPathComponent().path
            if parent != context && !parent.hasPrefix(context + "/") { folders.append(parent) }
        }
        return folders
    }

    /// Borrow the build's folders when this process is sandboxed, then find the Dockerfile.
    /// Returns its absolute path, or `-` when `file` is `-` (read from standard input).
    ///
    /// The engine holds what the user has granted and asks the app for the rest, so a build
    /// in a folder nobody has granted raises the same panel a mount of it would. Only once
    /// the folder can be read does "no Dockerfile" mean what it says. `secretFiles` are
    /// borrowed as well, since reading them is this process's read too.
    ///
    /// Throws ``BuildInputError`` for a folder that could not be borrowed or a missing
    /// context or Dockerfile.
    public static func resolveBuildFile(
        contextDir: String,
        file: String?,
        secretFiles: [String] = [],
        log: Logger
    ) async throws -> String {
        if file == "-" { return "-" }
        let contextDir = HostPath.absolute(contextDir)
        if ClientHostDirectory.isSandboxed {
            for folder in foldersToBorrow(contextDir: contextDir, file: file) {
                let outcome = try await ClientHostDirectory.lend(path: folder)
                guard case .granted = outcome else {
                    throw BuildInputError(outcome.message(for: folder, verb: "read"))
                }
                log.debug("borrowed a folder for the build", metadata: ["path": "\(folder)"])
            }
            try await ClientHostDirectory.borrow(secretFiles, verb: "read")
        }

        guard FileManager.default.fileExists(atPath: contextDir) else {
            throw BuildInputError("context dir does not exist \(contextDir)")
        }
        if let file {
            let path = HostPath.absolute(file)
            guard FileManager.default.fileExists(atPath: path) else {
                throw BuildInputError("dockerfile does not exist \(file)")
            }
            return path
        }
        guard let found = try BuildFile.resolvePath(contextDir: contextDir) else {
            // "Not found" and "not allowed to look" arrive here as the same answer, because
            // `FileManager.fileExists` returns false for both. The lend above should have
            // settled that; listing the directory tells them apart if it did not.
            guard (try? FileManager.default.contentsOfDirectory(atPath: contextDir)) != nil else {
                throw BuildInputError(
                    "cannot read context dir \(contextDir): permission denied. "
                        + "This build of the CLI is sandboxed and reads only what it has been granted.")
            }
            throw BuildInputError("dockerfile not found in context dir")
        }
        guard FileManager.default.fileExists(atPath: found) else {
            throw BuildInputError("dockerfile does not exist \(found)")
        }
        return found
    }

    // MARK: - Dockerfile

    /// The largest Dockerfile a build accepts, in bytes. See
    /// https://github.com/apple/container/issues/735.
    public static let maxBuildFileSize = 16 * 1024  // 16 KiB

    /// Read the Dockerfile at `path` and the `<path>.dockerignore` beside it, when there is one.
    public static func readBuildFile(at path: String) throws -> (dockerfile: Data, dockerignore: Data?) {
        let ignoreFileURL = URL(filePath: path + ".dockerignore")
        let buildFileData = try Data(contentsOf: URL(filePath: path))
        let ignoreFileData = try? Data(contentsOf: ignoreFileURL)
        return (buildFileData, ignoreFileData)
    }

    /// Reject a Dockerfile of ``maxBuildFileSize`` bytes or more before a build is attempted.
    // BUG: See https://github.com/apple/container/issues/735.
    // TODO: Remove when #735 was been resolved.
    public static func checkBuildFileSize(_ buildFileData: Data) throws {
        guard buildFileData.count < maxBuildFileSize else {
            throw ContainerizationError(
                .invalidArgument,
                message: """
                    Dockerfile size (\(buildFileData.count) bytes) exceeds the maximum allowed size of \(maxBuildFileSize) bytes. \
                    See https://github.com/apple/container/issues/735.
                    """
            )
        }
    }

    // MARK: - Secrets

    /// A build secret: its value, or the file that holds it.
    public enum Secret: Sendable, Equatable, Decodable {
        case data(Data)
        case file(String)
    }

    /// The files among `secrets`, for ``resolveBuildFile(contextDir:file:secretFiles:log:)``
    /// to borrow.
    public static func secretFiles(_ secrets: [String: Secret]) -> [String] {
        secrets.values.compactMap { secret -> String? in
            if case .file(let path) = secret { return path }
            return nil
        }
    }

    /// The value of each secret, reading the ones held in files.
    public static func readSecrets(_ secrets: [String: Secret]) throws -> [String: Data] {
        try secrets.mapValues { secret in
            switch secret {
            case .data(let data):
                return data
            case .file(let path):
                return try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Platforms, tags and exports

    /// The platforms to build for: `platforms` when any are given, else the
    /// `CONTAINER_DEFAULT_PLATFORM` environment variable, else every `os`/`arch` pair.
    ///
    /// Throws ``BuildInputError`` for a platform or an os/architecture pair that does not parse.
    public static func resolvePlatforms(
        platforms: [String],
        os: [String],
        arch: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: Logger? = nil
    ) throws -> Set<Platform> {
        var results: Set<Platform> = []
        for platform in platforms {
            guard let p = try? Platform(from: platform) else {
                throw BuildInputError("invalid platform specified \(platform)")
            }
            results.insert(p)
        }

        if !results.isEmpty {
            return results
        }

        if let envPlatform = try DefaultPlatform.fromEnvironment(environment: environment, log: log) {
            return [envPlatform]
        }

        for o in os {
            for a in arch {
                guard let platform = try? Platform(from: "\(o)/\(a)") else {
                    throw BuildInputError("invalid os/architecture combination \(o)/\(a)")
                }
                results.insert(platform)
            }
        }
        return results
    }

    /// The normalized form of each image name (a missing tag becomes `latest`), as the built
    /// image is tagged.
    public static func normalizedTags(_ names: [String]) throws -> [String] {
        try names.map { name in
            let parsedReference = try Reference.parse(name)
            parsedReference.normalize()
            return parsedReference.description
        }
    }

    /// Parse `--output` values. An export without a destination writes
    /// `<exportDirectory>/out.tar`, where the builder's export mount puts it.
    public static func exports(from outputs: [String], exportDirectory: URL) throws -> [BuildExport] {
        try outputs.map { output in
            var exp = try BuildExport(from: output)
            if exp.destination == nil {
                exp.destination = exportDirectory.appendingPathComponent("out.tar")
            }
            return exp
        }
    }

    /// Make a fresh folder for one build's exports, `<app root>/builder/<buildID>`, inside the
    /// folder the builder container mounts. The caller removes it when the build is done.
    public static func createExportDirectory(buildID: String) async throws -> URL {
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportPath = systemHealth.appRoot
            .appendingPathComponent(resourceDirectory)
        let tempURL = exportPath.appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        return tempURL
    }

    /// What a build produced.
    public struct BuildOutcome: Sendable, Equatable {
        /// The tags the image was given, normalized.
        public let tags: [String]
        /// Where a `tar` or `local` export was written; `nil` for an image loaded into the store.
        public let destination: URL?

        public init(tags: [String], destination: URL?) {
            self.tags = tags
            self.destination = destination
        }

        /// The line `container build` prints when it is done: the tags, one per line, or the
        /// path a `tar` or `local` export was written to.
        public var summary: String {
            if let destination {
                return destination.absolutePath()
            }
            return tags.joined(separator: "\n")
        }
    }

    /// Deliver what BuildKit exported: load an `oci` export into the image store, unpack it
    /// for this host and tag it with `tags`; move a `tar` export, or copy a `local` one, to
    /// its destination.
    ///
    /// Reports one task per export and the unpack's entries through `progressUpdate`.
    public static func storeExports(
        _ exports: [BuildExport],
        tags: [String],
        exportDirectory: URL,
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws -> BuildOutcome {
        var destination: URL?
        let taskManager = ProgressTaskCoordinator()
        // Currently, only a single export can be specified.
        for exp in exports {
            await progressUpdate([.addTasks(1)])
            let unpackTask = await taskManager.startTask()
            switch exp.type {
            case "oci":
                try Task.checkCancellation()
                guard let dest = exp.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                }
                let result = try await ClientImage.load(from: dest.absolutePath(), force: false)
                guard result.rejectedMembers.isEmpty else {
                    log.error("archive contains invalid members", metadata: ["paths": "\(result.rejectedMembers)"])
                    throw ContainerizationError(.internalError, message: "failed to load archive")
                }
                for image in result.images {
                    try Task.checkCancellation()
                    try await image.unpackForHost(progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressUpdate))

                    // Tag the unpacked image with all requested tags
                    for tagName in tags {
                        try Task.checkCancellation()
                        _ = try await image.tag(new: tagName)
                    }
                }
            case "tar":
                guard let dest = exp.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                }
                let tarURL = exportDirectory.appendingPathComponent("out.tar")
                try FileManager.default.moveItem(at: tarURL, to: dest)
                destination = dest
            case "local":
                guard let dest = exp.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required \(exp.rawValue)")
                }
                let localDir = exportDirectory.appendingPathComponent("local")

                guard FileManager.default.fileExists(atPath: localDir.path) else {
                    throw ContainerizationError(.invalidArgument, message: "expected local output not found")
                }
                try FileManager.default.copyItem(at: localDir, to: dest)
                destination = dest
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid exporter \(exp.rawValue)")
            }
        }
        await taskManager.finish()
        return BuildOutcome(tags: tags, destination: destination)
    }

    // MARK: - End to end

    /// One build, as `container build` takes it.
    public struct BuildRequest: Sendable {
        /// The build context folder. Absolute: a relative path resolves against `PWD`.
        public var contextDir: String
        /// The Dockerfile; `nil` finds `Dockerfile` or `Containerfile` in the context.
        public var file: String?
        /// Names for the built image; empty gives it a random one, as `container build` does.
        public var tags: [String]
        /// `key=value` build arguments.
        public var buildArgs: [String]
        /// `key=value` image labels.
        public var labels: [String]
        public var secrets: [String: Secret]
        /// The stage to build; empty builds the last one.
        public var target: String
        /// `os/arch[/variant]` values; empty takes `CONTAINER_DEFAULT_PLATFORM`, else
        /// `linux` on the host's architecture.
        public var platforms: [String]
        public var noCache: Bool
        public var pull: Bool
        /// Suppress BuildKit's output.
        public var quiet: Bool
        /// `--output` values, `type=<oci|tar|local>[,dest=]`.
        public var outputs: [String]
        public var cacheIn: [String]
        public var cacheOut: [String]
        /// How to start the builder. Its `ssh` also forwards the SSH agent into the build.
        public var builder: StartOptions
        public var vsockPort: UInt32

        public init(
            contextDir: String,
            file: String? = nil,
            tags: [String] = [],
            buildArgs: [String] = [],
            labels: [String] = [],
            secrets: [String: Secret] = [:],
            target: String = "",
            platforms: [String] = [],
            noCache: Bool = false,
            pull: Bool = false,
            quiet: Bool = false,
            outputs: [String] = ["type=oci"],
            cacheIn: [String] = [],
            cacheOut: [String] = [],
            builder: StartOptions = .init(),
            vsockPort: UInt32 = Builder.defaultVsockPort
        ) {
            self.contextDir = contextDir
            self.file = file
            self.tags = tags
            self.buildArgs = buildArgs
            self.labels = labels
            self.secrets = secrets
            self.target = target
            self.platforms = platforms
            self.noCache = noCache
            self.pull = pull
            self.quiet = quiet
            self.outputs = outputs
            self.cacheIn = cacheIn
            self.cacheOut = cacheOut
            self.builder = builder
            self.vsockPort = vsockPort
        }
    }

    /// Run a build end to end, the steps `container build` takes: borrow the context folders,
    /// start the builder and connect to it, build, then load the export into the image store,
    /// unpack it for this host and tag it.
    ///
    /// BuildKit writes its own output to `terminal` (a pty from `Terminal.create()` works), or
    /// to standard error when it is `nil`. The builder's start and the unpack report through
    /// `progressUpdate`; `willBuild` runs just before BuildKit takes over the output.
    public static func build(
        _ request: BuildRequest,
        terminal: Terminal?,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        progressUpdate: @escaping ProgressUpdateHandler,
        willBuild: @escaping @Sendable () async -> Void = {}
    ) async throws -> BuildOutcome {
        let dockerfile = try await resolveBuildFile(
            contextDir: request.contextDir,
            file: request.file,
            secretFiles: secretFiles(request.secrets),
            log: log
        )
        guard dockerfile != "-" else {
            throw BuildInputError("a Dockerfile from standard input is not supported here")
        }
        let contextDir = HostPath.absolute(request.contextDir)

        let builder = try await connect(
            request.builder,
            vsockPort: request.vsockPort,
            containerSystemConfig: containerSystemConfig,
            log: log,
            progressUpdate: progressUpdate
        )

        // `builder.build` shuts the builder down when it ends. A failure before it gets there
        // must do the same, or the connection and its event loops stay behind; a second
        // shutdown after the build does nothing.
        do {
            let (buildFileData, ignoreFileData) = try readBuildFile(at: dockerfile)
            try checkBuildFileSize(buildFileData)
            let secretsData = try readSecrets(request.secrets)

            let buildID = UUID().uuidString
            let exportDirectory = try await createExportDirectory(buildID: buildID)
            defer {
                try? FileManager.default.removeItem(at: exportDirectory)
            }

            let imageNames = try normalizedTags(request.tags.isEmpty ? [UUID().uuidString.lowercased()] : request.tags)
            let exports = try exports(from: request.outputs, exportDirectory: exportDirectory)
            let platforms = try resolvePlatforms(
                platforms: request.platforms,
                os: ["linux"],
                arch: [ContainerAPIClient.Arch.hostArchitecture().rawValue],
                log: log
            )

            let config = BuildConfig(
                buildID: buildID,
                contentStore: RemoteContentStoreClient(),
                buildArgs: request.buildArgs,
                secrets: secretsData,
                ssh: request.builder.ssh ? "default" : "",
                contextDir: contextDir,
                dockerfile: buildFileData,
                dockerignore: ignoreFileData,
                labels: request.labels,
                noCache: request.noCache,
                platforms: [Platform](platforms),
                terminal: terminal,
                tags: imageNames,
                target: request.target,
                quiet: request.quiet,
                exports: exports,
                cacheIn: request.cacheIn,
                cacheOut: request.cacheOut,
                pull: request.pull,
                containerSystemConfig: containerSystemConfig,
            )
            await willBuild()
            try await builder.build(config)

            await progressUpdate([
                .setDescription("Unpacking built image"),
                .setItemsName("entries"),
                .setTasks(0),
                .setTotalTasks(exports.count),
            ])
            return try await storeExports(
                exports,
                tags: imageNames,
                exportDirectory: exportDirectory,
                log: log,
                progressUpdate: progressUpdate
            )
        } catch {
            await builder.shutdown()
            throw error
        }
    }
}
