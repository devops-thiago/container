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
import NIOHTTP1
import Synchronization

extension ImageRoutes {
    /// Pull, list, inspect, history, tag, push, delete, save, load and prune.
    ///
    /// - Parameters:
    ///   - containers: the engine's containers, for what uses an image.
    ///   - scratch: where `save` has the engine write its archive and a load body that was
    ///     not spooled is written; somewhere the images service can read and write. A spooled
    ///     load body goes to `DockerHTTPLimits.spoolDirectory`, which must be such a place too.
    ///   - maxLoadBytes: the largest archive `POST /images/load` takes. Its body is spooled to a
    ///     file under this bound instead of being held in memory.
    ///   - events: where pulls, pushes, tags and deletes are reported; nil reports nothing.
    public static func register(
        on router: inout DockerRouter, engine: some EngineImages, containers: some EngineContainers, identities: DockerIdentityStore,
        scratch: URL, maxLoadBytes: Int = defaultMaxLoadBytes, progressInterval: Duration = .milliseconds(100), events: DockerEventBus? = nil
    ) {
        register(on: &router, engine: engine, progressInterval: progressInterval, events: events)
        let routes = StoreRoutes(
            engine: engine, containers: containers, identities: identities, scratch: scratch, progressInterval: progressInterval, events: events)
        // Literal paths first: they tie on literal segments with the `{name+}` patterns.
        router.add(.GET, "/images/json") { request, _ in try await routes.list(request) }
        router.add(.GET, "/images/get") { request, _ in try await routes.save(request.query["names"] ?? [], request) }
        router.add(.POST, "/images/load", body: .spool(maxBytes: maxLoadBytes)) { request, _ in try await routes.load(request) }
        router.add(.POST, "/images/prune") { request, _ in try await routes.prune(request) }
        router.add(.GET, "/images/{name+}/json") { _, parameters in try await routes.inspect(try parameters["name"]) }
        router.add(.GET, "/images/{name+}/history") { _, parameters in try await routes.history(try parameters["name"]) }
        router.add(.GET, "/images/{name+}/get") { request, parameters in try await routes.save([try parameters["name"]], request) }
        router.add(.POST, "/images/{name+}/tag") { request, parameters in try await routes.tag(try parameters["name"], request) }
        router.add(.POST, "/images/{name+}/push") { request, parameters in try await routes.push(try parameters["name"], request) }
        router.add(.DELETE, "/images/{name+}") { request, parameters in try await routes.delete(try parameters["name"], request) }
    }

    /// The largest image archive `POST /images/load` takes: an archive is as large as its image.
    public static let defaultMaxLoadBytes = 32 << 30

    struct StoreRoutes<Engine: EngineImages, Containers: EngineContainers>: Sendable {
        let engine: Engine
        let containers: Containers
        let identities: DockerIdentityStore
        let scratch: URL
        let progressInterval: Duration
        let events: DockerEventBus?

        /// An image event as dockerd reports one: by the image's ID, or by the reference for a
        /// pull or push, with the name it concerns.
        func report(_ action: String, _ actorID: String, name: String) async {
            await events?.publish(type: "image", action: action, actorID: actorID, attributes: ["name": name])
        }

        /// What a delete or prune did, item by item: `untag` for a reference, `delete` for the
        /// image.
        func report(_ items: [DockerImageDeleteItem], imageID: String) async {
            for item in items {
                if item.Untagged != nil { await report("untag", imageID, name: imageID) }
                if let deleted = item.Deleted { await report("delete", deleted, name: deleted) }
            }
        }

        func catalog() async throws -> DockerImageCatalog {
            DockerImageCatalog(try await engine.list())
        }

        func dockerContainers() async throws -> [DockerContainer] {
            try await identities.join { try await containers.list() }
        }

        func list(_ request: DockerRequest) async throws -> DockerResponse {
            let catalog = try await catalog()
            let filter = try ImageListFilter(filters: try request.filters(), catalog: catalog)
            let manifests = try request.bool("manifests")
            let containers = manifests ? try await dockerContainers() : []
            return try .json(filter.apply(catalog).map { ImageViewMapper.summary($0, manifests: manifests, containers: containers) })
        }

        func inspect(_ name: String) async throws -> DockerResponse {
            try .json(ImageViewMapper.inspect(try await catalog().resolve(name).image))
        }

        func history(_ name: String) async throws -> DockerResponse {
            try .json(ImageViewMapper.history(try await catalog().resolve(name).image))
        }

        /// `POST /images/{name}/tag?repo=&tag=`: 201 with no body.
        func tag(_ name: String, _ request: DockerRequest) async throws -> DockerResponse {
            let target = try Self.target(repo: request.query("repo") ?? "", tag: request.query("tag") ?? "")
            let match = try await catalog().resolve(name)
            try await engine.tag((match.record ?? match.image.primary).reference, as: target.normalized)
            // Named now, it is no longer dangling: its reserved reference goes, as in dockerd.
            if target.name != EngineImageRecord.danglingRepository {
                for marker in match.image.records where marker.isDanglingMarker {
                    try? await engine.delete(marker.reference)
                }
            }
            await report("tag", match.image.id, name: target.familiar)
            return .empty(.created)
        }

        /// The reference a tag makes, refused as dockerd refuses it.
        static func target(repo: String, tag: String) throws(DockerAPIError) -> DockerImageReference {
            guard !repo.isEmpty else { throw .badRequest("repository name must have at least one component") }
            var target = try DockerImageReference(repo, defaultTag: false)
            guard target.digest == nil else { throw .badRequest("refusing to create a tag with a digest reference") }
            if !tag.isEmpty {
                guard DockerPullReference.isValidTag(tag) else { throw .badRequest("invalid tag format") }
                target = target.tagged(tag)
            } else if target.tag == nil {
                target = target.tagged("latest")
            }
            guard target.familiarName != "sha256" else {
                throw .badRequest("refusing to create an ambiguous tag using digest algorithm as name")
            }
            return target
        }

        /// `DELETE /images/{name}?force=&noprune=`: Docker's untagged and deleted lines.
        ///
        /// After an image is deleted its content is collected, as `container image delete` does;
        /// that collection is the engine's, of whatever no reference needs. `noprune` skips it.
        func delete(_ name: String, _ request: DockerRequest) async throws -> DockerResponse {
            let force = try request.bool("force")
            let noprune = try request.bool("noprune")
            let match = try await catalog().resolve(name)
            let plan = try ImageDeletion.plan(match, force: force, containers: try await dockerContainers())
            for record in plan.remove {
                try await engine.delete(record.reference)
            }
            await report(plan.items, imageID: match.image.id)
            if !noprune && plan.items.contains(where: { $0.Deleted != nil }) {
                _ = try? await engine.collectGarbage()
            }
            return try .json(plan.items)
        }

        /// `POST /images/prune`: removes what `ImageDeletion.pruneSelection` picks, skipping an
        /// image it cannot remove, as dockerd does. Content is collected only when an image went.
        func prune(_ request: DockerRequest) async throws -> DockerResponse {
            let selected = try ImageDeletion.pruneSelection(try await catalog(), filters: try request.filters(), containers: try await dockerContainers())
            var items: [DockerImageDeleteItem] = []
            for image in selected {
                var untagged: [DockerImageDeleteItem] = []
                do {
                    for record in image.records {
                        try await engine.delete(record.reference)
                        if !record.isDanglingMarker { untagged.append(.untagged(record.familiarReference)) }
                    }
                    items += untagged + [.deleted(image.id)]
                    await report(untagged + [.deleted(image.id)], imageID: image.id)
                } catch {
                    items += untagged
                    await report(untagged, imageID: image.id)
                }
            }
            let reclaimed = items.contains { $0.Deleted != nil } ? ((try? await engine.collectGarbage()) ?? 0) : 0
            return try .json(DockerImagePruneReport(ImagesDeleted: items.isEmpty ? nil : items, SpaceReclaimed: reclaimed))
        }

        /// `GET /images/get?names=` and `GET /images/{name}/get`: the engine writes the archive
        /// into scratch before the head, so a failure is a status; it is then streamed out and
        /// deleted, however the stream ends.
        func save(_ names: [String], _ request: DockerRequest) async throws -> DockerResponse {
            guard !names.isEmpty else { throw DockerAPIError.badRequest("no image names were given to save") }
            let platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
            try ImageRoutes.validate(platform: platform)
            let catalog = try await catalog()
            var references: [String] = []
            for name in names {
                let match = try catalog.resolve(name)
                let reference = (match.record ?? match.image.primary).reference
                if !references.contains(reference) { references.append(reference) }
            }
            let file = scratch.appending(path: "docker-save-\(UUID().uuidString).tar")
            do {
                try await engine.save(references: references, platform: platform, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            return .stream(status: .ok, contentType: "application/x-tar") { writer in
                defer { try? FileManager.default.removeItem(at: file) }
                try await DockerScratchFile.stream(file, to: writer)
            }
        }

        /// `POST /images/load?quiet=`: Docker's `{"stream":"Loaded image: …"}` lines. As dockerd
        /// does, the answer is 200 and a failure is the stream's last line.
        ///
        /// The body is a file the HTTP layer spooled, which it deletes once the answer is sent;
        /// a body it kept in memory is written to scratch here and deleted here.
        func load(_ request: DockerRequest) async throws -> DockerResponse {
            let platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
            try ImageRoutes.validate(platform: platform)
            let file: URL
            let owned: Bool
            if let spooled = request.bodyFile {
                file = spooled
                owned = false
            } else {
                guard request.body.readableBytes > 0 else { throw DockerAPIError.badRequest("request body is empty") }
                file = scratch.appending(path: "docker-load-\(UUID().uuidString).tar")
                try Data(request.body.readableBytesView).write(to: file, options: .withoutOverwriting)
                owned = true
            }
            return .stream(status: .ok, contentType: "application/json") { writer in
                defer { if owned { try? FileManager.default.removeItem(at: file) } }
                let loaded: DockerLoadedImages
                let catalog: DockerImageCatalog
                do {
                    loaded = try await engine.load(from: file)
                    catalog = try await self.catalog()
                } catch {
                    try await writer.writeJSON(DockerProgressMessage.failure((error as? DockerAPIError)?.message ?? "\(error)"))
                    return
                }
                for line in Self.loadedLines(loaded, catalog: catalog) {
                    try await writer.writeJSON(DockerStreamLine(stream: line))
                }
            }
        }

        /// `Loaded image: alpine:latest` for a reference that names the image by a tag or a
        /// digest, `Loaded image ID: sha256:…` for an image loaded without one.
        static func loadedLines(_ loaded: DockerLoadedImages, catalog: DockerImageCatalog) -> [String] {
            var lines: [String] = []
            for reference in loaded.references {
                let match = catalog.images.lazy.compactMap { image in
                    image.records.first { $0.reference == reference }.map { (image, $0) }
                }.first
                guard let (image, record) = match else { continue }
                let line = record.isNamed ? "Loaded image: \(record.familiarReference)\n" : "Loaded image ID: \(image.id)\n"
                if !lines.contains(line) { lines.append(line) }
            }
            if !loaded.rejectedMembers.isEmpty {
                lines.append("Skipped archive entries with unsafe paths: \(loaded.rejectedMembers.joined(separator: ", "))\n")
            }
            return lines
        }

        /// `POST /images/{name}/push?tag=`: Docker's JSON progress, then the digest line and the
        /// `aux` record the CLI reads. Without a tag, every tag of the repository is pushed.
        ///
        /// Refusals come before the head; a failure after it is the stream's last line.
        func push(_ name: String, _ request: DockerRequest) async throws -> DockerResponse {
            let tag = request.query("tag") ?? ""
            let platform = request.query("platform").flatMap { $0.isEmpty ? nil : $0 }
            try ImageRoutes.validate(platform: platform)
            // The client's credential for this push, passed to the images service for it alone:
            // neither kept nor logged. Without one, the engine's own logins are used.
            let credential = DockerRegistryAuth.credential(header: request.headers.first(name: DockerRegistryAuth.header))
            var named = try DockerImageReference(name, defaultTag: false)
            if !tag.isEmpty {
                guard DockerPullReference.isValidTag(tag) else { throw DockerAPIError.badRequest("invalid tag format") }
                named = named.tagged(tag)
            }
            let records = Self.pushRecords(named, in: try await catalog())
            guard !records.isEmpty else {
                throw DockerAPIError.notFound("An image does not exist locally with the tag: \(named.familiar)")
            }
            let interval = progressInterval
            let repository = named.name
            return .stream(status: .ok, contentType: "application/json") { writer in
                try await writer.writeJSON(DockerProgressMessage(status: "The push refers to repository [\(repository)]"))
                for record in records {
                    let id = record.parsed?.tag ?? record.parsed?.digest ?? record.reference
                    let pushed: DockerDescriptor?
                    do {
                        pushed = try await Self.push(
                            record, platform: platform, credential: credential, id: id, engine: engine, writer: writer, interval: interval)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try await writer.writeJSON(DockerProgressMessage.failure((error as? DockerAPIError)?.message ?? "\(error)"))
                        return
                    }
                    // A digest is only reported when it is the one the registry has: pinning
                    // an image by a digest it does not serve would fail later, and far away.
                    if let parsed = record.parsed {
                        await self.report("push", parsed.familiar, name: parsed.familiarName)
                    }
                    guard let pushed else { continue }
                    try await writer.writeJSON(DockerProgressMessage(status: "\(id): digest: \(pushed.digest) size: \(pushed.size)"))
                    try await writer.writeJSON(DockerAuxMessage(aux: .init(Tag: record.parsed?.tag ?? "", Digest: pushed.digest, Size: pushed.size)))
                }
            }
        }

        /// The references a push sends: the one tag named, or every tag of the repository.
        static func pushRecords(_ named: DockerImageReference, in catalog: DockerImageCatalog) -> [EngineImageRecord] {
            let all = catalog.images.flatMap(\.records)
            if named.tag != nil || named.digest != nil {
                return all.filter { $0.parsed == named }
            }
            return all.filter { $0.parsed?.name == named.name && $0.isTagged }.sorted { $0.reference < $1.reference }
        }

        static func push(
            _ record: EngineImageRecord, platform: String?, credential: DockerRegistryCredential?, id: String, engine: Engine,
            writer: DockerResponseWriter, interval: Duration
        ) async throws -> DockerDescriptor? {
            let (updates, continuation) = AsyncStream.makeStream(of: DockerPullProgress.self, bufferingPolicy: .bufferingNewest(1))
            let state = Mutex(DockerPullProgress())
            let pushing = Task {
                defer { continuation.finish() }
                return try await engine.push(reference: record.reference, platform: platform, credential: credential) { events in
                    continuation.yield(
                        state.withLock { progress in
                            progress.apply(events)
                            return progress
                        })
                }
            }
            do {
                try await withTaskCancellationHandler {
                    for await progress in updates {
                        let total = progress.totalSize > 0 ? progress.totalSize : nil
                        let current = total.map { min(progress.size, $0) } ?? progress.size
                        try await writer.writeJSON(
                            DockerProgressMessage(
                                status: "Pushing", id: id, progressDetail: .init(current: current, total: total),
                                progress: DockerPullProgress.bar(current: current, total: total)))
                        try await Task.sleep(for: interval)
                    }
                } onCancel: {
                    pushing.cancel()
                }
                let pushed = try await pushing.value
                try await writer.writeJSON(DockerProgressMessage(status: "Pushed", id: id))
                return pushed
            } catch {
                pushing.cancel()
                throw error
            }
        }
    }
}

/// `{"stream": …}`: a line of text in Docker's JSON message stream.
struct DockerStreamLine: Encodable, Sendable {
    let stream: String
}

/// The `aux` record that ends a push, which the CLI reads the digest from.
struct DockerAuxMessage: Encodable, Sendable {
    struct PushResult: Encodable, Sendable {
        let Tag: String
        let Digest: String
        let Size: Int64
    }

    let progressDetail = DockerEmptyObject()
    let aux: PushResult
}
