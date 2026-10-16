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

import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// One build as the engine's builder takes it.
public struct DockerBuildRequest: Sendable {
    /// The unpacked context, a directory made for this build alone.
    public var context: URL
    public var dockerfile: Data
    /// The context's `.dockerignore`, when it has one.
    public var dockerignore: Data?
    /// The engine references to tag the image with, in Docker's normal form
    /// (`docker.io/library/web:latest`). Never empty.
    public var tags: [String]
    /// `key=value`, sorted by key.
    public var buildArgs: [String]
    /// `key=value`, sorted by key.
    public var labels: [String]
    /// The stage to build; empty builds the last one.
    public var target: String
    public var noCache: Bool
    /// Pull base images even when they are here.
    public var pull: Bool
    /// `os/arch[/variant]`; nil builds for the host.
    public var platform: String?
    /// The client's registry credentials, by registry host (`docker.io`), for the pulls the
    /// build makes. Used for this build alone: never kept and never logged.
    public var credentials: [String: DockerRegistryCredential]

    public init(
        context: URL, dockerfile: Data, dockerignore: Data? = nil, tags: [String], buildArgs: [String] = [], labels: [String] = [],
        target: String = "", noCache: Bool = false, pull: Bool = false, platform: String? = nil,
        credentials: [String: DockerRegistryCredential] = [:]
    ) {
        self.context = context
        self.dockerfile = dockerfile
        self.dockerignore = dockerignore
        self.tags = tags
        self.buildArgs = buildArgs
        self.labels = labels
        self.target = target
        self.noCache = noCache
        self.pull = pull
        self.platform = platform
        self.credentials = credentials
    }
}

/// The engine's builder as `POST /build` sees it. The agent runs `container build`'s pipeline;
/// tests answer from a fake.
public protocol EngineBuilder: Sendable {
    /// Starts the builder when it needs it, builds, and loads, unpacks and tags the image with
    /// every one of `request.tags`. The builder's own output is handed to `output` as it
    /// arrives, in pieces that need not end at a line. Returns once nothing of the build is
    /// running any more, including when it is cancelled, so the context can go.
    func build(_ request: DockerBuildRequest, output: @escaping @Sendable (Data) async -> Void) async throws
}

/// `POST /build`, the classic builder's API, which `DOCKER_BUILDKIT=0 docker build` uses, and
/// `POST /build/prune`.
public enum BuildRoutes {
    /// - Parameters:
    ///   - images: the engine's images, for the built image's ID.
    ///   - scratch: where each build's context is unpacked, in a `build-<id>` directory removed
    ///     once the build is over. The spooled body goes to `DockerHTTPLimits.spoolDirectory`.
    ///   - events: where the tags a build makes are reported; nil reports nothing.
    public static func register(
        on router: inout DockerRouter, builder: some EngineBuilder, images: some EngineImages, scratch: URL, limits: DockerBuildLimits = .init(),
        events: DockerEventBus? = nil
    ) {
        let routes = Routes(builder: builder, images: images, scratch: scratch, limits: limits, events: events)
        router.add(.POST, "/build", body: .spool(maxBytes: limits.maxBodyBytes)) { request, _ in try await routes.build(request) }
        // The builder keeps its cache in its own VM and offers no way to prune it from here.
        router.add(.POST, "/build/prune") { _, _ in try .json(PruneReport(CachesDeleted: [], SpaceReclaimed: 0)) }
    }

    struct PruneReport: Encodable {
        let CachesDeleted: [String]
        let SpaceReclaimed: Int64
    }

    /// The parameters of one build, read and checked before anything is unpacked.
    struct Parameters: Equatable {
        var dockerfile = DockerBuildContext.defaultDockerfile
        /// As the client named them, normalized; empty when it named none.
        var tags: [DockerImageReference] = []
        var buildArgs: [String] = []
        var labels: [String] = []
        var target = ""
        var noCache = false
        var pull = false
        var platform: String?
        var quiet = false

        init() {}

        /// Reads the query as dockerd does, refusing what this builder cannot do.
        init(_ request: DockerRequest) throws(DockerAPIError) {
            switch request.query("version") ?? "" {
            case "", "1":
                break
            case "2":
                throw .badRequest(
                    "BuildKit (version=2) is not supported by SiliconShip's Docker API: build with DOCKER_BUILDKIT=0, or use container build")
            case let other:
                throw .badRequest("invalid version \"\(other)\"")
            }
            if let remote = request.query("remote"), !remote.isEmpty {
                throw .badRequest("a remote build context (\(remote)) is not supported by SiliconShip: send the context in the request body")
            }
            if let name = request.query("dockerfile"), !name.isEmpty { dockerfile = name }
            for text in request.query["t"] ?? [] where !text.isEmpty {
                let reference = try DockerImageReference(text)
                guard reference.digest == nil else { throw .badRequest("invalid tag \(text): refusing to create a tag with a digest reference") }
                if !tags.contains(reference) { tags.append(reference) }
            }
            buildArgs = try Self.pairs(request.query("buildargs"), name: "build args")
            labels = try Self.pairs(request.query("labels"), name: "labels")
            target = request.query("target") ?? ""
            noCache = try request.bool("nocache")
            pull = try request.bool("pull")
            quiet = try request.bool("q")
            platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
            try ImageRoutes.validate(platform: platform)
        }

        /// A JSON object of strings as `key=value`, sorted by key. A null value, which the CLI
        /// sends for a `--build-arg` it found no value for, is left out: the build sees the
        /// argument's default.
        static func pairs(_ text: String?, name: String) throws(DockerAPIError) -> [String] {
            guard let text, !text.isEmpty else { return [] }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw .badRequest("error reading \(name): \(text) is not a JSON object")
            }
            var pairs: [String] = []
            for key in object.keys.sorted() {
                switch object[key] {
                case let value as String:
                    pairs.append("\(key)=\(value)")
                case is NSNull:
                    continue
                default:
                    throw .badRequest("error reading \(name): the value of \(key) is not a string")
                }
            }
            return pairs
        }
    }

    struct Routes<Builder: EngineBuilder, Images: EngineImages>: Sendable {
        let builder: Builder
        let images: Images
        let scratch: URL
        let limits: DockerBuildLimits
        let events: DockerEventBus?

        /// `POST /build`: the context in the body, the image's progress as Docker's JSON
        /// message stream.
        ///
        /// Everything that can be refused is refused before the head: the parameters, the
        /// context and the Dockerfile. After it, a failure is the stream's last line, as dockerd
        /// answers a build that fails. The context is removed once the build is over, however
        /// it ends.
        func build(_ request: DockerRequest) async throws -> DockerResponse {
            let parameters = try Parameters(request)
            // Every registry credential the client has; kept for this build and never logged.
            let credentials = DockerRegistryAuth.credentials(configHeader: request.headers.first(name: DockerRegistryAuth.configHeader))
            let directory = scratch.appending(path: "build-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
            let prepared: DockerBuildContext
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                prepared = try DockerBuildContext.prepare(body: try body(request, in: directory), dockerfile: parameters.dockerfile, in: directory, limits: limits)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if let error = error as? DockerAPIError { throw error }
                throw DockerAPIError.internalError("could not store the build context: \(error)")
            }
            // Without a name the image still needs one here, as `container build` gives it.
            let tags = parameters.tags.isEmpty ? [try DockerImageReference(UUID().uuidString.lowercased())] : parameters.tags
            let build = DockerBuildRequest(
                context: prepared.context, dockerfile: prepared.dockerfile, dockerignore: prepared.dockerignore, tags: tags.map(\.normalized),
                buildArgs: parameters.buildArgs, labels: parameters.labels, target: parameters.target, noCache: parameters.noCache,
                pull: parameters.pull, platform: parameters.platform, credentials: credentials)
            return .stream(status: .ok, contentType: "application/json") { writer in
                defer { try? FileManager.default.removeItem(at: directory) }
                try await self.run(build, named: parameters.tags, quiet: parameters.quiet, writer: writer)
            }
        }

        /// The body as a file: the one the HTTP layer spooled, or one written here from a body
        /// held in memory.
        func body(_ request: DockerRequest, in directory: URL) throws -> URL {
            if let spooled = request.bodyFile { return spooled }
            let file = directory.appending(path: "body")
            try Data(request.body.readableBytesView).write(to: file, options: .withoutOverwriting)
            return file
        }

        /// Runs the build and writes its stream: the builder's output as `stream` lines, then
        /// the image's ID as `aux`, then `Successfully built` and a `Successfully tagged` line
        /// for each name the client gave. With `quiet`, only the ID is written, as a `stream`
        /// line, unless the build fails: then what it wrote comes first, as dockerd does.
        func run(_ build: DockerBuildRequest, named: [DockerImageReference], quiet: Bool, writer: DockerResponseWriter) async throws {
            let output = DockerBuildOutput(writer: writer, quiet: quiet)
            let id: String
            do {
                try await builder.build(build) { await output.append($0) }
                await output.finish()
                try Task.checkCancellation()
                id = try DockerImageCatalog(try await images.list()).resolve(build.tags[0]).image.id
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await output.finish()
                await output.release()
                try await writer.writeJSON(DockerProgressMessage.failure((error as? DockerAPIError)?.message ?? "\(error)"))
                return
            }
            for reference in named {
                await events?.publish(type: "image", action: "tag", actorID: id, attributes: ["name": reference.familiar])
            }
            if quiet {
                try await writer.writeJSON(DockerStreamLine(stream: id + "\n"))
                return
            }
            try await writer.writeJSON(DockerBuildResult(ID: id))
            let short = String((id.split(separator: ":").last.map(String.init) ?? id).prefix(12))
            try await writer.writeJSON(DockerStreamLine(stream: "Successfully built \(short)\n"))
            for reference in named {
                try await writer.writeJSON(DockerStreamLine(stream: "Successfully tagged \(reference.familiar)\n"))
            }
        }
    }
}

/// The `aux` record a classic build sends with the image's ID, which the CLI reads it from.
struct DockerBuildResult: Encodable, Sendable {
    struct Result: Encodable, Sendable {
        let ID: String
    }

    let id = "moby.image.id"
    let aux: Result

    init(ID: String) {
        aux = Result(ID: ID)
    }
}

/// The builder's output as Docker's `{"stream": …}` lines: one per line of text, cut at
/// newlines whatever pieces it arrived in. With `quiet` the lines are kept back instead, the
/// most recent `maxQuietBytes` of them, for `release` to write should the build fail.
actor DockerBuildOutput {
    /// The longest piece held waiting for its newline; a longer one goes out as it is.
    static let maxLineBytes = 1 << 16
    static let maxQuietBytes = 1 << 20

    let writer: DockerResponseWriter
    let quiet: Bool
    private var partial: [UInt8] = []
    private var held: [String] = []
    private var heldBytes = 0
    /// Set once a write failed: the client has gone, and the rest is dropped.
    private var gone = false

    init(writer: DockerResponseWriter, quiet: Bool) {
        self.writer = writer
        self.quiet = quiet
    }

    func append(_ data: Data) async {
        for byte in data {
            partial.append(byte)
            if byte == UInt8(ascii: "\n") || partial.count >= Self.maxLineBytes {
                await emit()
            }
        }
    }

    /// Ends a line the output left open.
    func finish() async {
        if !partial.isEmpty {
            partial.append(UInt8(ascii: "\n"))
            await emit()
        }
    }

    /// Writes what `quiet` held back.
    func release() async {
        let lines = held
        held = []
        heldBytes = 0
        for line in lines { await write(line) }
    }

    private func emit() async {
        let line = String(decoding: partial, as: UTF8.self)
        partial = []
        guard quiet else {
            await write(line)
            return
        }
        held.append(line)
        heldBytes += line.utf8.count
        while heldBytes > Self.maxQuietBytes, !held.isEmpty {
            heldBytes -= held.removeFirst().utf8.count
        }
    }

    private func write(_ line: String) async {
        guard !gone else { return }
        do {
            try await writer.writeJSON(DockerStreamLine(stream: line))
        } catch {
            gone = true
        }
    }
}
