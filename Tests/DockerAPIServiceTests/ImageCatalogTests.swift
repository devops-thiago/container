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

import ContainerResource
import Foundation
import Testing

@testable import DockerAPIService

/// The image model: references, grouping by ID, lookup, the views, the list filter, and what
/// a delete or a prune takes.
struct ImageCatalogTests {
    typealias F = StoreFixtures

    static let alpine = F.record("docker.io/library/alpine:latest", id: "a", created: 1_700_000_300)
    static let alpineTag = F.record("docker.io/library/alpine:3.22", id: "a", created: 1_700_000_300)
    static let mine = F.record("docker.io/library/m229-x:1", id: "a", created: 1_700_000_300)
    static let alpineDigest = F.record("docker.io/library/alpine@" + F.digest("a"), id: "a", created: 1_700_000_300)
    static let redis = F.record("docker.io/library/redis:8", id: "b", created: 1_700_000_200, labels: ["tier": "cache"])
    static let ghcr = F.record("ghcr.io/org/app:1", id: "c", target: "d", created: 1_700_000_100, labels: ["tier": "web", "m229": "1"])
    /// Pulled by digest: named, so not dangling.
    static let pinned = F.record("docker.io/library/old@" + F.digest("e"), id: "e", created: 1_700_000_000, labels: ["m229": "1"])
    /// Named by neither a tag nor a digest: dangling.
    static let untagged = F.record("docker.io/library/scratch", id: "9", created: 1_699_999_000)
    static let vminit = F.record("ghcr.io/apple/containerization/vminit:0.9", id: "f", infrastructure: true)

    static let catalog = DockerImageCatalog([alpine, alpineTag, mine, redis, ghcr, pinned, untagged, vminit])

    @Test("a reference is put in Docker's normal form and printed familiar")
    func references() throws {
        let short = try DockerImageReference("alpine")
        #expect(short.normalized == "docker.io/library/alpine:latest")
        #expect(short.familiar == "alpine:latest")
        let org = try DockerImageReference("org/app:2")
        #expect(org.normalized == "docker.io/org/app:2")
        #expect(org.familiarName == "org/app")
        let registry = try DockerImageReference("localhost:5000/team/app")
        #expect(registry.normalized == "localhost:5000/team/app:latest")
        #expect(registry.familiar == "localhost:5000/team/app:latest")
        let hub = try DockerImageReference("index.docker.io/library/busybox:1")
        #expect(hub.familiar == "busybox:1")
        let pinned = try DockerImageReference("ghcr.io/org/app@" + F.digest("d"))
        #expect(pinned.tag == nil)
        #expect(pinned.familiar == "ghcr.io/org/app@" + F.digest("d"))
        #expect(try DockerImageReference("alpine", defaultTag: false).tag == nil)
        // Control: what Docker's grammar refuses.
        for bad in ["Alpine", "alpine:", "alpine:bad tag", "/x", "a@sha256:short"] {
            #expect(throws: DockerAPIError.self, "\(bad)") { try DockerImageReference(bad) }
        }
    }

    @Test("references with one ID are one image, newest first, without the engine's own")
    func grouping() throws {
        #expect(Self.catalog.images.map(\.id) == [F.digest("a"), F.digest("b"), F.digest("c"), F.digest("e"), F.digest("9")])
        let alpine = Self.catalog.images[0]
        #expect(alpine.repoTags == ["alpine:3.22", "alpine:latest", "m229-x:1"])
        #expect(alpine.repoDigests == ["alpine@" + F.digest("a"), "m229-x@" + F.digest("a")])
        #expect(!alpine.isDangling)
        #expect(alpine.shortID == "aaaaaaaaaaaa")
        let old = Self.catalog.images[3]
        #expect(old.repoTags.isEmpty)
        #expect(old.repoDigests == ["old@" + F.digest("e")])
        // A digest names it: not dangling, as in Docker 29.
        #expect(!old.isDangling)
        let scratch = Self.catalog.images[4]
        #expect(scratch.repoTags.isEmpty)
        #expect(scratch.isDangling)
        // Control: the init image is not anywhere a client can reach.
        #expect(throws: DockerAPIError.self) { try Self.catalog.resolve("ghcr.io/apple/containerization/vminit:0.9") }
        #expect(throws: DockerAPIError.self) { try Self.catalog.resolve(F.digest("f")) }
    }

    @Test("a name resolves by full ID or target digest, reference, digest, then a unique ID prefix")
    func resolve() throws {
        let catalog = Self.catalog
        #expect(try catalog.resolve(F.digest("b")).image.id == F.digest("b"))
        #expect(try catalog.resolve(F.digest("b")).record == nil)
        // The index digest of `ghcr.io/org/app` stands for the image too.
        #expect(try catalog.resolve(F.digest("d")).image.id == F.digest("c"))
        #expect(try catalog.resolve("alpine").record?.reference == "docker.io/library/alpine:latest")
        #expect(try catalog.resolve("docker.io/library/alpine:3.22").record?.reference == "docker.io/library/alpine:3.22")
        #expect(try catalog.resolve("ghcr.io/org/app:1").image.id == F.digest("c"))
        #expect(try catalog.resolve("ghcr.io/org/app@" + F.digest("d")).image.id == F.digest("c"))
        #expect(try catalog.resolve("bbbb").image.id == F.digest("b"))
        #expect(try catalog.resolve("bbbb").record == nil)

        #expect(throws: DockerAPIError.notFound("No such image: redis:latest")) { try catalog.resolve("redis") }
        #expect(throws: DockerAPIError.notFound("No such image: 0123:latest")) { try catalog.resolve("0123") }
        #expect(throws: DockerAPIError.badRequest("image name cannot be blank")) { try catalog.resolve(" ") }
        let twins = DockerImageCatalog([F.record("docker.io/library/x:1", id: "1"), F.record("docker.io/library/y:1", id: "1")])
        #expect(try twins.resolve("1111").image.records.count == 2)
        let close = DockerImageCatalog([
            F.record("docker.io/library/x:1", id: "1"),
            EngineImageRecord(
                reference: "docker.io/library/y:1", target: .init(mediaType: "m", digest: F.digest("9"), size: 1), id: "sha256:11" + String(repeating: "2", count: 62), size: 1,
                config: nil),
        ])
        #expect(throws: DockerAPIError.badRequest("multiple IDs found with provided prefix: 11")) { try close.resolve("11") }
    }

    @Test("a container uses an image by recorded ID, by index digest, or by reference")
    func containerUse() throws {
        let image = Self.catalog.images[0]
        let byIndex = DockerContainer(snapshot: F.container("c1", image: Self.alpine), dockerID: Fixtures.id("c1"), name: "c1")
        var other = F.container("c2", image: Self.redis)
        other.configuration.labels[DockerLabels.imageID] = F.digest("a")
        let byLabel = DockerContainer(snapshot: other, dockerID: Fixtures.id("c2"), name: "c2")
        var named = F.container("c3", image: Self.redis)
        named.configuration.image = ImageDescription(reference: "docker.io/library/m229-x:1", descriptor: .init(mediaType: "m", digest: F.digest("9"), size: 1))
        let byReference = DockerContainer(snapshot: named, dockerID: Fixtures.id("c3"), name: "c3")
        let unrelated = DockerContainer(snapshot: F.container("c4", image: Self.redis), dockerID: Fixtures.id("c4"), name: "c4")
        let users = DockerImageCatalog.containers(using: image, among: [byIndex, byLabel, byReference, unrelated])
        #expect(users.map(\.name) == ["c1", "c2", "c3"])
    }

    @Test("a container the engine made alone reports its image's config digest as ImageID, as the image list does")
    func containerImageID() throws {
        let foreign = DockerContainer(snapshot: F.container("c1", image: Self.ghcr), dockerID: Fixtures.id("c1"), name: "c1")
        let context = DockerViewContext(now: Fixtures.now, builtinNetwork: Fixtures.builtin, imageIDs: [F.digest("d"): F.digest("c")])
        #expect(ContainerViewMapper.summary(foreign, context: context).ImageID == F.digest("c"))
        #expect(ContainerViewMapper.inspect(foreign, context: context).Image == F.digest("c"))
        // Control: without the mapping it is the index digest, and what this service recorded wins.
        let bare = DockerViewContext(now: Fixtures.now, builtinNetwork: Fixtures.builtin)
        #expect(ContainerViewMapper.summary(foreign, context: bare).ImageID == F.digest("d"))
        var labelled = foreign
        labelled.snapshot.configuration.labels[DockerLabels.imageID] = F.digest("9")
        #expect(ContainerViewMapper.summary(labelled, context: context).ImageID == F.digest("9"))
        let filter = try ContainerListFilter(filters: ["ancestor": ["cccccccc"]], all: true, limit: nil, context: context)
        #expect(filter.matches(foreign))
    }

    @Test("the summary, the inspect and the history have Docker's fields")
    func views() throws {
        let image = Self.catalog.images[0]
        let user = DockerContainer(snapshot: F.container("c1", image: Self.alpine, run: .running), dockerID: Fixtures.id("c1"), name: "c1")
        let summary = ImageViewMapper.summary(image, manifests: true, containers: [user])
        #expect(summary.Id == F.digest("a"))
        #expect(summary.Created == 1_700_000_300)
        #expect(summary.SharedSize == -1 && summary.Containers == -1)
        #expect(summary.Descriptor.digest == F.digest("a"))
        let manifests = try #require(summary.Manifests)
        #expect(manifests.map(\.Kind) == ["image", "image", "attestation"])
        #expect(manifests[0].ImageData?.Containers == [Fixtures.id("c1")])
        #expect(manifests[1].ImageData?.Containers == [])
        #expect(manifests[1].Available == false)
        #expect(manifests[2].AttestationData?.For == F.digest("m"))
        // Control: without `manifests=1` there are none.
        #expect(ImageViewMapper.summary(image, manifests: false, containers: [user]).Manifests == nil)

        let inspect = ImageViewMapper.inspect(image)
        #expect(inspect.Architecture == "arm64" && inspect.Os == "linux")
        #expect(inspect.RootFS.Layers == [F.digest("1"), F.digest("2")])
        #expect(inspect.Created == "2023-11-14T22:18:20.000Z")
        let json = String(decoding: try DockerJSON.encoder.encode(inspect), as: UTF8.self)
        #expect(json.contains(#""Entrypoint":null"#))
        #expect(json.contains(#""Cmd":["\/bin\/sh"]"#) || json.contains(#""Cmd":["/bin/sh"]"#))
        #expect(!json.contains("ExposedPorts"))

        let history = ImageViewMapper.history(image)
        #expect(history.map(\.CreatedBy) == ["RUN apk add curl", "ENV PATH=/bin", "ADD rootfs.tar /"])
        #expect(history.map(\.Size) == [900_000, 0, 3_000_000])
        #expect(history.map(\.Id) == [F.digest("a"), "<missing>", "<missing>"])
        #expect(history[0].Tags == image.repoTags)
        #expect(history[1].Tags == nil)
        let line = String(decoding: try DockerJSON.encoder.encode(history[1]), as: UTF8.self)
        #expect(line.contains(#""Tags":null"#))
    }

    @Test("the list filter: dangling, label, reference globs, before and since, and refusals")
    func listFilter() throws {
        let catalog = Self.catalog
        func ids(_ filters: [String: [String]]) throws -> [String] {
            try ImageListFilter(filters: filters, catalog: catalog).apply(catalog).map { String($0.id.suffix(1)) }
        }
        #expect(try ids([:]) == ["a", "b", "c", "e", "9"])
        // The image pulled by digest is not dangling; only the one named by neither is.
        #expect(try ids(["dangling": ["true"]]) == ["9"])
        #expect(try ids(["dangling": ["false"]]) == ["a", "b", "c", "e"])
        #expect(try ids(["label": ["tier"]]) == ["b", "c"])
        #expect(try ids(["label": ["tier=web"]]) == ["c"])
        #expect(try ids(["before": ["redis:8"]]) == ["c", "e", "9"])
        #expect(try ids(["since": ["redis:8"]]) == ["a"])
        #expect(try ids(["reference": ["alpine"]]) == ["a"])
        #expect(try ids(["reference": ["ghcr.io/*/app"]]) == ["c"])
        // A glob does not cross `/`.
        #expect(try ids(["reference": ["ghcr.io/*"]]) == [])
        let filtered = try ImageListFilter(filters: ["reference": ["alpine:3.*"]], catalog: catalog).apply(catalog)
        #expect(filtered.first?.repoTags == ["alpine:3.22"])

        #expect(throws: DockerAPIError.badRequest("invalid filter 'dangling=[maybe]'")) {
            try ImageListFilter(filters: ["dangling": ["maybe"]], catalog: catalog)
        }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'dangling=[true false]'")) {
            try ImageListFilter(filters: ["dangling": ["true", "false"]], catalog: catalog)
        }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'colour'")) { try ImageListFilter(filters: ["colour": ["x"]], catalog: catalog) }
        #expect(throws: DockerAPIError.badRequest("the 'until' filter is not supported")) {
            try ImageListFilter(filters: ["until": ["1h"]], catalog: catalog)
        }
        #expect(throws: DockerAPIError.badRequest("syntax error in pattern: [")) { try ImageListFilter(filters: ["reference": ["["]], catalog: catalog) }
        #expect(throws: DockerAPIError.self) { try ImageListFilter(filters: ["before": ["nope"]], catalog: catalog) }
    }

    @Test("globs follow Go's path.Match")
    func globs() throws {
        let cases: [(String, String, Bool)] = [
            ("alpine", "alpine", true), ("alp*", "alpine", true), ("a?pine", "alpine", true), ("*", "a/b", false), ("*/b", "a/b", true),
            ("[a-c]pine", "bpine", true), ("[^a-c]pine", "bpine", false), ("[!a]x", "!x", true), ("\\*", "*", true), ("\\*", "a", false),
            ("a*b*c", "axxbyyc", true), ("a*b", "acb/b", false), ("", "", true), ("x", "", false),
        ]
        for (pattern, name, expected) in cases {
            #expect(try DockerFilters.glob(pattern, name) == expected, "\(pattern) \(name)")
        }
        for bad in ["[", "[]", "a\\", "[a-"] {
            #expect(throws: DockerFilters.BadPattern.self, "\(bad)") { try DockerFilters.glob(bad, "abc") }
        }
    }

    func container(_ name: String, _ record: EngineImageRecord, _ run: StoreFixtures.Run) -> DockerContainer {
        DockerContainer(snapshot: F.container(name, image: record, run: run), dockerID: Fixtures.id(name), name: name)
    }

    @Test("deleting by reference untags it, and deletes the image only with its last reference")
    func deleteByReference() throws {
        let catalog = Self.catalog
        let untag = try ImageDeletion.plan(try catalog.resolve("m229-x:1"), force: false, containers: [container("c1", Self.alpine, .running)])
        #expect(untag.remove.map(\.reference) == ["docker.io/library/m229-x:1"])
        #expect(untag.items == [.untagged("m229-x:1")])

        // The last tag of a repository takes its digest references along.
        let pinned = DockerImageCatalog([Self.alpine, Self.alpineDigest, Self.mine])
        let withDigest = try ImageDeletion.plan(try pinned.resolve("alpine"), force: false, containers: [])
        #expect(withDigest.items == [.untagged("alpine:latest"), .untagged("alpine@" + F.digest("a"))])
        #expect(withDigest.remove.count == 2)

        let single = DockerImageCatalog([Self.redis])
        let gone = try ImageDeletion.plan(try single.resolve("redis:8"), force: false, containers: [])
        #expect(gone.items == [.untagged("redis:8"), .deleted(F.digest("b"))])

        let users = [container("cafe", Self.redis, .exited)]
        #expect(
            throws: DockerAPIError.conflict(
                "conflict: unable to delete redis:8 (must be forced) - container cafe00000000 is using its referenced image bbbbbbbbbbbb")
        ) { try ImageDeletion.plan(try single.resolve("redis:8"), force: false, containers: users) }
        // Control: forced, it goes.
        #expect(try ImageDeletion.plan(try single.resolve("redis:8"), force: true, containers: users).items.last == .deleted(F.digest("b")))
    }

    @Test("deleting by ID takes every reference, and dockerd's conflicts hold it back")
    func deleteByID() throws {
        let single = DockerImageCatalog([Self.redis])
        let several = DockerImageCatalog([Self.alpine, Self.mine])
        let running = [container("beef", Self.redis, .running)]
        let stopped = [container("cafe", Self.redis, .exited)]
        let hard = DockerAPIError.conflict("conflict: unable to delete bbbbbbbbbbbb (cannot be forced) - image is being used by running container beef00000000")
        #expect(throws: hard) { try ImageDeletion.plan(try single.resolve("bbbb"), force: false, containers: running) }
        #expect(throws: hard) { try ImageDeletion.plan(try single.resolve("bbbb"), force: true, containers: running) }
        #expect(throws: DockerAPIError.conflict("conflict: unable to delete bbbbbbbbbbbb (must be forced) - image is being used by stopped container cafe00000000")) {
            try ImageDeletion.plan(try single.resolve("bbbb"), force: false, containers: stopped)
        }
        #expect(throws: DockerAPIError.conflict("conflict: unable to delete aaaaaaaaaaaa (must be forced) - image is referenced in multiple repositories")) {
            try ImageDeletion.plan(try several.resolve(F.digest("a")), force: false, containers: [])
        }
        let forced = try ImageDeletion.plan(try several.resolve(F.digest("a")), force: true, containers: [])
        #expect(forced.items == [.untagged("alpine:latest"), .untagged("m229-x:1"), .deleted(F.digest("a"))])
        // Control: one repository's tag and digest are not "multiple repositories".
        let one = DockerImageCatalog([Self.alpine, Self.alpineDigest])
        #expect(try ImageDeletion.plan(try one.resolve("aaaa"), force: false, containers: []).items.last == .deleted(F.digest("a")))
        #expect(try ImageDeletion.plan(try single.resolve("bbbb"), force: true, containers: stopped).items.last == .deleted(F.digest("b")))
    }

    @Test("a prune takes dangling images (not those pulled by digest), or with dangling=false every unused one, by label, never one in use or the engine's")
    func pruneSelection() throws {
        let catalog = Self.catalog
        func ids(_ filters: [String: [String]], _ containers: [DockerContainer] = []) throws -> [String] {
            try ImageDeletion.pruneSelection(catalog, filters: filters, containers: containers).map { String($0.id.suffix(1)) }
        }
        // A plain prune keeps the image pulled by digest and takes the one named by neither.
        #expect(try ids([:]) == ["9"])
        #expect(try ids(["dangling": ["false"]]) == ["a", "b", "c", "e", "9"])
        #expect(try ids(["dangling": ["false"]], [container("c1", Self.alpine, .exited)]) == ["b", "c", "e", "9"])
        #expect(try ids(["dangling": ["false"], "label": ["m229=1"]]) == ["c", "e"])
        #expect(try ids(["dangling": ["false"], "label": ["m229=1"], "label!": ["tier=web"]]) == ["e"])
        // Control: an image without the label is never picked by a label filter.
        #expect(try ids(["dangling": ["false"], "label": ["m229=2"]]) == [])
        #expect(throws: DockerAPIError.badRequest("the 'until' filter is not supported")) { try ids(["until": ["24h"]]) }
        #expect(throws: DockerAPIError.badRequest("invalid filter 'reference'")) { try ids(["reference": ["x"]]) }
    }
}
