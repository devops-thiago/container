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
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Testing

@testable import ContainerImagesService

/// A `docker save` archive built from scratch: one layer tar, a config whose diff
/// ID is that layer's digest, and the `manifest.json`, `repositories` and per-layer
/// files Docker Image Specification v1.2 lays out around them.
private struct DockerArchiveFixture {
    static let platform = Platform(arch: "arm64", os: "linux")
    /// Docker names a layer's directory by a legacy ID, not by its digest.
    static let layerID = String(repeating: "a", count: 64)

    let root: URL
    let layerDigest: String
    let configDigest: String
    let configFileName: String
    let layerMember: String

    /// Write the archive into `root`, which must exist.
    @discardableResult
    static func write(in root: URL, repoTags: [String]? = ["example/app:1"], layerFilter: ContainerizationArchive.Filter = .none) throws -> Self {
        let layerMember = "\(Self.layerID)/layer.tar"
        let layerDirectory = root.appendingPathComponent(Self.layerID)
        try FileManager.default.createDirectory(at: layerDirectory, withIntermediateDirectories: true)
        try Self.writeLayer(to: root.appendingPathComponent(layerMember), filter: layerFilter)
        try "1.0".write(to: layerDirectory.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try "{\"id\":\"\(Self.layerID)\"}".write(to: layerDirectory.appendingPathComponent("json"), atomically: true, encoding: .utf8)
        let layerDigest = try Self.digest(of: root.appendingPathComponent(layerMember))

        let config = try Self.config(diffIDs: [layerDigest])
        let configDigest = SHA256.hash(data: config).digestString
        let configFileName = "\(SHA256.hash(data: config).encoded).json"
        try config.write(to: root.appendingPathComponent(configFileName))

        let entry = DockerImageArchive.ManifestEntry(config: configFileName, repoTags: repoTags, layers: [layerMember])
        try Self.writeManifest([entry], in: root)
        try "{\"example/app\":{\"1\":\"\(Self.layerID)\"}}".write(
            to: root.appendingPathComponent("repositories"), atomically: true, encoding: .utf8)
        return Self(root: root, layerDigest: layerDigest, configDigest: configDigest, configFileName: configFileName, layerMember: layerMember)
    }

    static func writeManifest(_ entries: [DockerImageArchive.ManifestEntry], in root: URL) throws {
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("manifest.json"))
    }

    static func writeLayer(to url: URL, filter: ContainerizationArchive.Filter = .none) throws {
        let writer = try ArchiveWriter(format: .pax, filter: filter, file: url)
        let content = Data("hello from the fixture\n".utf8)
        let entry = WriteEntry()
        entry.path = "hello.txt"
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = Int64(content.count)
        entry.modificationDate = Date(timeIntervalSince1970: 0)
        try writer.writeEntry(entry: entry, data: content)
        try writer.finishEncoding()
    }

    static func config(diffIDs: [String]) throws -> Data {
        let image = ContainerizationOCI.Image(
            created: "2026-01-01T00:00:00Z",
            architecture: Self.platform.architecture,
            os: Self.platform.os,
            config: ImageConfig(cmd: ["/bin/sh"]),
            rootfs: Rootfs(type: "layers", diffIDs: diffIDs))
        return try JSONEncoder().encode(image)
    }

    static func digest(of file: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: file)).digestString
    }
}

/// An `ImagesService` over stores in a temporary directory, with no daemon behind it.
private struct ServiceFixture {
    let service: ImagesService
    let imageStore: ImageStore

    init(root: URL, log: Logger) throws {
        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        self.imageStore = try ImageStore(path: root.appendingPathComponent("images"), contentStore: contentStore)
        let snapshotStore = try SnapshotStore(path: root.appendingPathComponent("snapshots"), unpackStrategy: { _, _ in nil }, log: nil)
        self.service = try ImagesService(contentStore: contentStore, imageStore: self.imageStore, snapshotStore: snapshotStore, log: log)
    }
}

struct DockerImageArchiveTests {
    private let log = Logger(label: "docker-image-archive-tests")

    private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func pack(_ directory: URL, to file: URL) throws {
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: file)
        try writer.archiveDirectory(directory)
        try writer.finishEncoding()
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    // MARK: Recognising the shapes

    @Test func recognisesADockerArchive() async throws {
        try await withTemporaryDirectory { root in
            try DockerArchiveFixture.write(in: root)
            #expect(DockerImageArchive.needsConversion(at: root))
            #expect(!DockerImageArchive.isOCILayout(at: root))
        }
    }

    @Test func leavesAnOCILayoutAlone() async throws {
        try await withTemporaryDirectory { root in
            // Docker with the containerd store writes a manifest.json beside its layout.
            try DockerArchiveFixture.write(in: root)
            try "{\"imageLayoutVersion\":\"1.0.0\"}".write(to: root.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)
            try "{\"schemaVersion\":2,\"manifests\":[]}".write(to: root.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
            #expect(!DockerImageArchive.needsConversion(at: root))
            #expect(DockerImageArchive.isOCILayout(at: root))
        }
    }

    @Test func recognisesNeitherShape() async throws {
        try await withTemporaryDirectory { root in
            try "hello".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            #expect(!DockerImageArchive.needsConversion(at: root))
            #expect(!DockerImageArchive.isOCILayout(at: root))

            // Half a layout is not a layout either.
            try "{\"imageLayoutVersion\":\"1.0.0\"}".write(to: root.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)
            #expect(!DockerImageArchive.isOCILayout(at: root))
        }
    }

    // MARK: Converting for the loader

    @Test func convertsADockerArchiveIntoALayoutTheStoreLoads() async throws {
        try await withTemporaryDirectory { root in
            let archive = try makeDirectory(root.appendingPathComponent("archive"))
            let fixture = try DockerArchiveFixture.write(in: archive)

            let rejected = try DockerImageArchive(log: log).convertToOCILayout(at: archive)
            #expect(rejected.isEmpty)

            let layout = try decode([String: String].self, at: archive.appendingPathComponent("oci-layout"))
            #expect(layout["imageLayoutVersion"] == "1.0.0")
            let index = try decode(Index.self, at: archive.appendingPathComponent("index.json"))
            let descriptor = try #require(index.manifests.first)
            #expect(index.manifests.count == 1)
            #expect(descriptor.mediaType == MediaTypes.imageManifest)
            #expect(descriptor.platform == DockerArchiveFixture.platform)
            let expectedName = "docker.io/example/app:1"
            #expect(descriptor.annotations?[AnnotationKeys.containerizationImageName] == expectedName)
            #expect(descriptor.annotations?[AnnotationKeys.containerdImageName] == expectedName)
            #expect(descriptor.annotations?[AnnotationKeys.openContainersImageName] == expectedName)

            // The blobs are the archive's own files, linked rather than copied.
            let blobs = archive.appendingPathComponent("blobs/sha256")
            let layerBlob = blobs.appendingPathComponent(try fixture.layerDigest.validatedDigestEncoding())
            let configBlob = blobs.appendingPathComponent(try fixture.configDigest.validatedDigestEncoding())
            #expect(try inode(of: layerBlob) == inode(of: archive.appendingPathComponent(fixture.layerMember)))
            #expect(try inode(of: configBlob) == inode(of: archive.appendingPathComponent(fixture.configFileName)))

            // The store's loader accepts the result and finds the image under its normalized name.
            let store = try ImageStore(path: root.appendingPathComponent("store"))
            let loaded = try await store.load(from: archive)
            let image = try #require(loaded.first)
            #expect(loaded.count == 1)
            #expect(image.reference == expectedName)
            let manifest = try await image.manifest(for: DockerArchiveFixture.platform)
            #expect(manifest.config.digest == fixture.configDigest)
            #expect(manifest.config.mediaType == MediaTypes.imageConfig)
            #expect(manifest.layers.map(\.digest) == [fixture.layerDigest])
            #expect(manifest.layers.map(\.mediaType) == [MediaTypes.imageLayer])
            let config = try await image.config(for: DockerArchiveFixture.platform)
            #expect(config.rootfs.diffIDs == [fixture.layerDigest])
        }
    }

    @Test func namesTheImageOncePerRepoTag() async throws {
        try await withTemporaryDirectory { root in
            try DockerArchiveFixture.write(in: root, repoTags: ["example/app:1", "example/app", "nginx:latest", "localhost:5000/app:2"])

            let rejected = try DockerImageArchive(log: log).convertToOCILayout(at: root)
            #expect(rejected.isEmpty)

            let index = try decode(Index.self, at: root.appendingPathComponent("index.json"))
            let names = index.manifests.compactMap { $0.annotations?[AnnotationKeys.containerdImageName] }
            #expect(names == ["docker.io/example/app:1", "docker.io/example/app:latest", "docker.io/library/nginx:latest", "localhost:5000/app:2"])
            #expect(Set(index.manifests.map(\.digest)).count == 1)
        }
    }

    @Test func reportsAnImageWithoutRepoTagsInsteadOfLoadingIt() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try DockerArchiveFixture.write(in: root)
            let tagged = DockerImageArchive.ManifestEntry(config: fixture.configFileName, repoTags: ["example/app:1"], layers: [fixture.layerMember])
            let untagged = DockerImageArchive.ManifestEntry(config: fixture.configFileName, repoTags: nil, layers: [fixture.layerMember])
            try DockerArchiveFixture.writeManifest([untagged, tagged], in: root)

            let rejected = try DockerImageArchive(log: log).convertToOCILayout(at: root)
            #expect(rejected.count == 1)
            #expect(rejected.first?.contains("manifest.json[0]") == true)
            #expect(rejected.first?.contains(fixture.configFileName) == true)

            let index = try decode(Index.self, at: root.appendingPathComponent("index.json"))
            #expect(index.manifests.count == 1)
        }
    }

    @Test func refusesAnArchiveWithNoTaggedImage() async throws {
        try await withTemporaryDirectory { root in
            try DockerArchiveFixture.write(in: root, repoTags: [])
            #expect(throws: ContainerizationError.self) {
                try DockerImageArchive(log: log).convertToOCILayout(at: root)
            }
        }
    }

    @Test func refusesALayerCountThatDoesNotMatchTheConfig() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try DockerArchiveFixture.write(in: root)
            let entry = DockerImageArchive.ManifestEntry(
                config: fixture.configFileName, repoTags: ["example/app:1"], layers: [fixture.layerMember, fixture.layerMember])
            try DockerArchiveFixture.writeManifest([entry], in: root)
            #expect(throws: ContainerizationError.self) {
                try DockerImageArchive(log: log).convertToOCILayout(at: root)
            }
        }
    }

    @Test func refusesALayerWhoseDigestIsNotItsDiffID() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try DockerArchiveFixture.write(in: root)
            try Data("not the layer the config describes".utf8).write(to: root.appendingPathComponent(fixture.layerMember))
            #expect(throws: ContainerizationError.self) {
                try DockerImageArchive(log: log).convertToOCILayout(at: root)
            }
        }
    }

    @Test func acceptsACompressedLayerByItsOwnDigest() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try DockerArchiveFixture.write(in: root, layerFilter: .gzip)

            let rejected = try DockerImageArchive(log: log).convertToOCILayout(at: root)
            #expect(rejected.isEmpty)

            let index = try decode(Index.self, at: root.appendingPathComponent("index.json"))
            let descriptor = try #require(index.manifests.first)
            let manifest = try decode(
                Manifest.self, at: root.appendingPathComponent("blobs/sha256").appendingPathComponent(descriptor.digest.validatedDigestEncoding()))
            #expect(manifest.layers.map(\.mediaType) == [MediaTypes.imageLayerGzip])
            #expect(manifest.layers.map(\.digest) == [fixture.layerDigest])
        }
    }

    @Test func refusesAManifestThatReachesOutsideTheArchive() async throws {
        try await withTemporaryDirectory { root in
            let archive = try makeDirectory(root.appendingPathComponent("archive"))
            let fixture = try DockerArchiveFixture.write(in: archive)
            let outside = root.appendingPathComponent("outside.json")
            try FileManager.default.copyItem(at: archive.appendingPathComponent(fixture.configFileName), to: outside)

            let traversing = DockerImageArchive.ManifestEntry(config: "../outside.json", repoTags: ["example/app:1"], layers: [fixture.layerMember])
            try DockerArchiveFixture.writeManifest([traversing], in: archive)
            #expect(throws: ContainerizationError.self) {
                try DockerImageArchive(log: log).convertToOCILayout(at: archive)
            }

            // A symlink member the extractor let through must not be followed out either.
            try FileManager.default.createSymbolicLink(at: archive.appendingPathComponent("link"), withDestinationURL: root)
            let linked = DockerImageArchive.ManifestEntry(config: "link/outside.json", repoTags: ["example/app:1"], layers: [fixture.layerMember])
            try DockerArchiveFixture.writeManifest([linked], in: archive)
            #expect(throws: ContainerizationError.self) {
                try DockerImageArchive(log: log).convertToOCILayout(at: archive)
            }

            let blobs = try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent("blobs/sha256").path)
            #expect(blobs.isEmpty)
        }
    }

    // MARK: Through the service

    @Test func serviceLoadsADockerArchiveAndSavesOneDockerLoads() async throws {
        try await withTemporaryDirectory { root in
            let archive = try makeDirectory(root.appendingPathComponent("archive"))
            let fixture = try DockerArchiveFixture.write(in: archive)
            let dockerTar = root.appendingPathComponent("docker.tar")
            try pack(archive, to: dockerTar)

            let first = try ServiceFixture(root: root.appendingPathComponent("first"), log: log)
            let (images, rejected) = try await first.service.load(from: dockerTar, force: false)
            #expect(rejected.isEmpty)
            #expect(images.map(\.reference) == ["docker.io/example/app:1"])

            let savedTar = root.appendingPathComponent("saved.tar")
            try await first.service.save(references: ["docker.io/example/app:1"], out: savedTar, platform: DockerArchiveFixture.platform)

            let saved = try makeDirectory(root.appendingPathComponent("saved"))
            let savedRejects = try ArchiveReader(file: savedTar).extractContents(to: saved)
            #expect(savedRejects.isEmpty)
            #expect(DockerImageArchive.isOCILayout(at: saved))

            let configID = try fixture.configDigest.validatedDigestEncoding()
            let layerID = try fixture.layerDigest.validatedDigestEncoding()
            let entries = try decode([DockerImageArchive.ManifestEntry].self, at: saved.appendingPathComponent("manifest.json"))
            let entry = try #require(entries.first)
            #expect(entries.count == 1)
            #expect(entry.config == "blobs/sha256/\(configID)")
            #expect(entry.repoTags == ["docker.io/example/app:1"])
            #expect(entry.layers == ["blobs/sha256/\(layerID)"])
            for member in [entry.config] + entry.layers {
                #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent(member).path), "\(member) is in the archive")
            }
            let repositories = try decode([String: [String: String]].self, at: saved.appendingPathComponent("repositories"))
            #expect(repositories == ["docker.io/example/app": ["1": layerID]])

            // The saved archive is still the layout the loader always read.
            let second = try ServiceFixture(root: root.appendingPathComponent("second"), log: log)
            let (reloaded, reloadRejects) = try await second.service.load(from: savedTar, force: false)
            #expect(reloadRejects.isEmpty)
            #expect(reloaded.map(\.reference) == ["docker.io/example/app:1"])
            let image = try await second.imageStore.get(reference: "docker.io/example/app:1")
            let manifest = try await image.manifest(for: DockerArchiveFixture.platform)
            #expect(manifest.layers.map(\.digest) == [fixture.layerDigest])
        }
    }

    @Test func serviceRefusesAnArchiveOfNeitherShape() async throws {
        try await withTemporaryDirectory { root in
            let contents = try makeDirectory(root.appendingPathComponent("contents"))
            try "not an image".write(to: contents.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            let tar = root.appendingPathComponent("readme.tar")
            try pack(contents, to: tar)

            let fixture = try ServiceFixture(root: root.appendingPathComponent("store"), log: log)
            do {
                _ = try await fixture.service.load(from: tar, force: false)
                Issue.record("an archive of neither shape was loaded")
            } catch let error as ContainerizationError {
                #expect(error.code == .invalidArgument)
                #expect(error.message == "not an image archive: expected an OCI layout (oci-layout + index.json) or a `docker save` archive (manifest.json)")
            }
        }
    }

    // MARK: Compatibility files for docker load

    /// A layout as `ImageStore.save` leaves it: blobs for a config, a layer and a
    /// manifest, and whatever index entries the test wants pointing at them.
    private struct SyntheticLayout {
        let root: URL
        let blobs: URL
        let configDigest: String
        let layerDigest: String
        let manifest: Descriptor

        init(in root: URL) throws {
            self.root = root
            self.blobs = root.appendingPathComponent("blobs/sha256")
            try FileManager.default.createDirectory(at: self.blobs, withIntermediateDirectories: true)
            let writer = try ContentWriter(for: self.blobs)
            let layer = try writer.write(Data("layer bytes".utf8))
            self.layerDigest = layer.digest.digestString
            let config = try writer.write(try DockerArchiveFixture.config(diffIDs: [self.layerDigest]))
            self.configDigest = config.digest.digestString
            let manifest = try writer.create(
                from: Manifest(
                    config: Descriptor(mediaType: MediaTypes.imageConfig, digest: self.configDigest, size: config.size),
                    layers: [Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: self.layerDigest, size: layer.size)]))
            self.manifest = Descriptor(
                mediaType: MediaTypes.imageManifest, digest: manifest.digest.digestString, size: manifest.size, platform: DockerArchiveFixture.platform)
        }

        /// An index blob over `manifests`, as the store wraps every saved image in one.
        func index(over manifests: [Descriptor]) throws -> Descriptor {
            let written = try ContentWriter(for: self.blobs).create(from: Index(manifests: manifests))
            return Descriptor(mediaType: MediaTypes.index, digest: written.digest.digestString, size: written.size)
        }

        func named(_ descriptor: Descriptor, _ name: String) -> Descriptor {
            var named = descriptor
            named.annotations = [AnnotationKeys.containerizationImageName: name]
            return named
        }

        func writeIndex(_ manifests: [Descriptor]) throws {
            try "{\"imageLayoutVersion\":\"1.0.0\"}".write(to: self.root.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)
            try JSONEncoder().encode(Index(manifests: manifests)).write(to: self.root.appendingPathComponent("index.json"))
        }
    }

    @Test func writesManifestAndRepositoriesForEachSinglePlatformImage() async throws {
        try await withTemporaryDirectory { root in
            let layout = try SyntheticLayout(in: root)
            let wrapped = try layout.index(over: [layout.manifest])
            var other = layout.manifest
            other.platform = Platform(arch: "amd64", os: "linux")
            let multi = try layout.index(over: [layout.manifest, other])
            try layout.writeIndex([
                layout.named(layout.manifest, "docker.io/example/app:1"),
                layout.named(wrapped, "docker.io/example/app:2"),
                layout.named(multi, "docker.io/example/multi:1"),
                layout.named(layout.manifest, "untagged@\(layout.manifest.digest)"),
            ])

            try DockerImageArchive(log: log).writeCompatibilityFiles(in: root)

            let configID = try layout.configDigest.validatedDigestEncoding()
            let layerID = try layout.layerDigest.validatedDigestEncoding()
            let entries = try decode([DockerImageArchive.ManifestEntry].self, at: root.appendingPathComponent("manifest.json"))
            #expect(entries.count == 3)
            #expect(entries.map(\.repoTags) == [["docker.io/example/app:1"], ["docker.io/example/app:2"], nil])
            #expect(entries.allSatisfy { $0.config == "blobs/sha256/\(configID)" && $0.layers == ["blobs/sha256/\(layerID)"] })

            let repositories = try decode([String: [String: String]].self, at: root.appendingPathComponent("repositories"))
            #expect(repositories == ["docker.io/example/app": ["1": layerID, "2": layerID]])
        }
    }

    @Test func leavesTheFilesOutWhenNoImageSuitsDockerLoad() async throws {
        try await withTemporaryDirectory { root in
            let layout = try SyntheticLayout(in: root)
            var other = layout.manifest
            other.platform = Platform(arch: "amd64", os: "linux")
            let multi = try layout.index(over: [layout.manifest, other])
            try layout.writeIndex([layout.named(multi, "docker.io/example/multi:1")])

            try DockerImageArchive(log: log).writeCompatibilityFiles(in: root)

            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("repositories").path))
        }
    }
}
