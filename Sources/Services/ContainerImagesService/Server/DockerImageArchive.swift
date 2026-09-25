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

import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging

/// The archive shape that `docker save` writes and `docker load` reads.
///
/// Docker Image Specification v1.2 describes each image with an entry in
/// `manifest.json` that names its config file and its layer tars by path within
/// the archive; there is no OCI index. `ImageStore` reads only OCI layouts, so
/// such an archive is rewritten into one in place before it is loaded, and a
/// layout the store has just saved gains the two files a classic `docker load`
/// reads beside it. Docker itself has written an OCI layout with `manifest.json`
/// alongside since it moved to containerd, so an archive that carries both
/// shapes is read as a layout, which is what containerd does with it too.
struct DockerImageArchive {
    static let manifestFileName = "manifest.json"
    static let repositoriesFileName = "repositories"
    static let layoutFileName = "oci-layout"
    static let indexFileName = "index.json"
    static let blobsDirectoryName = "blobs/sha256"

    /// One image of `manifest.json`. Paths are relative to the archive root.
    struct ManifestEntry: Codable {
        enum CodingKeys: String, CodingKey {
            case config = "Config"
            case repoTags = "RepoTags"
            case layers = "Layers"
        }

        var config: String
        var repoTags: [String]?
        var layers: [String]
    }

    let log: Logger

    /// Whether an extracted archive is an OCI layout.
    static func isOCILayout(at directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent(Self.layoutFileName).path)
            && fm.fileExists(atPath: directory.appendingPathComponent(Self.indexFileName).path)
    }

    /// Whether an extracted archive is a Docker archive that has to be rewritten
    /// before `ImageStore` can load it.
    static func needsConversion(at directory: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: directory.appendingPathComponent(Self.layoutFileName).path)
            && fm.fileExists(atPath: directory.appendingPathComponent(Self.manifestFileName).path)
    }

    // MARK: Loading

    /// Rewrite a Docker archive, extracted into `directory`, as an OCI layout in
    /// the same directory.
    ///
    /// Each config and layer is hashed where it lies and hard-linked under
    /// `blobs/sha256` by its digest, so nothing is copied and nothing is written
    /// anywhere else; `ImageStore.load` then verifies every blob against its
    /// manifest as it does for any layout. Returns the entries that were left
    /// out: an image without `RepoTags` has no name the store could keep it under.
    func convertToOCILayout(at directory: URL) throws -> [String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let entries: [ManifestEntry] = try Self.decode(controlFile: root.appendingPathComponent(Self.manifestFileName))
        let blobs = try Self.blobsDirectory(in: root)

        var manifests: [Descriptor] = []
        var rejected: [String] = []
        for (position, entry) in entries.enumerated() {
            guard let repoTags = entry.repoTags, !repoTags.isEmpty else {
                self.log.warning("skipping an image without RepoTags", metadata: ["config": "\(entry.config)"])
                rejected.append("\(Self.manifestFileName)[\(position)] (\(entry.config)): no RepoTags")
                continue
            }
            let descriptor = try self.convert(entry, root: root, blobs: blobs)
            for repoTag in repoTags {
                let reference = try Self.normalizedReference(repoTag)
                var named = descriptor
                named.annotations = [
                    AnnotationKeys.containerizationImageName: reference,
                    AnnotationKeys.containerdImageName: reference,
                    AnnotationKeys.openContainersImageName: reference,
                ]
                manifests.append(named)
            }
        }
        guard !manifests.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "no image in \(Self.manifestFileName) has RepoTags")
        }

        // The archive may have put a member at either name, and a symlink member can
        // point outside the directory: an atomic write replaces the entry rather than
        // writing through it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Index(manifests: manifests)).write(to: root.appendingPathComponent(Self.indexFileName), options: .atomic)
        try encoder.encode(["imageLayoutVersion": "1.0.0"]).write(to: root.appendingPathComponent(Self.layoutFileName), options: .atomic)
        return rejected
    }

    /// Link one image's config and layers into the layout and write its manifest.
    private func convert(_ entry: ManifestEntry, root: URL, blobs: URL) throws -> Descriptor {
        let configFile = try Self.memberFile(entry.config, in: root)
        let config: ContainerizationOCI.Image = try Self.decode(controlFile: configFile)
        let diffIDs = config.rootfs.diffIDs
        guard diffIDs.count == entry.layers.count else {
            throw ContainerizationError(
                .invalidArgument,
                message: "\(entry.config) describes \(diffIDs.count) layers but \(Self.manifestFileName) lists \(entry.layers.count)")
        }

        var layers: [Descriptor] = []
        for (member, diffID) in zip(entry.layers, diffIDs) {
            let file = try Self.memberFile(member, in: root)
            let blob = try Self.digest(file)
            // A layer stored as it is has its diff ID for a digest. Docker refuses the
            // mismatch as well, and a corrupt layer found here is a clearer failure than
            // one found when the image is unpacked.
            if blob.mediaType == MediaTypes.imageLayer, blob.digest.digestString != diffID {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "layer \(member) has digest \(blob.digest.digestString) but \(entry.config) expects \(diffID)")
            }
            try Self.link(file, as: blob.digest, into: blobs)
            layers.append(Descriptor(mediaType: blob.mediaType, digest: blob.digest.digestString, size: blob.size))
        }

        let configBlob = try Self.digest(configFile)
        try Self.link(configFile, as: configBlob.digest, into: blobs)
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configBlob.digest.digestString, size: configBlob.size),
            layers: layers)
        let written = try ContentWriter(for: blobs).create(from: manifest)
        return Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: written.digest.digestString,
            size: written.size,
            platform: Platform(arch: config.architecture, os: config.os, osFeatures: config.osFeatures, variant: config.variant))
    }

    /// The store's name for a `RepoTags` entry. Docker's rules apply to what
    /// Docker wrote: a name without a registry is on `docker.io`, official images
    /// live under `library/`, and a name without a tag means `latest`.
    private static func normalizedReference(_ repoTag: String) throws -> String {
        var raw = repoTag
        if try Reference.parse(repoTag).domain == nil {
            raw = "docker.io/\(repoTag)"
        }
        let reference = try Reference.parse(raw)
        reference.normalize()
        return reference.description
    }

    private struct Blob {
        let digest: SHA256.Digest
        let size: Int64
        let mediaType: String
    }

    /// Hash a file where it lies. `docker save` writes layers as plain tars, other
    /// writers of the format compress them, and the first bytes tell which.
    private static func digest(_ file: URL) throws -> Blob {
        let content = try LocalContent(path: file)
        let head = try content.data(offset: 0, length: 4) ?? Data()
        let digest = try content.digest()
        let size = try content.size()
        return Blob(digest: digest, size: Int64(size), mediaType: Self.layerMediaType(head: head))
    }

    private static func layerMediaType(head: Data) -> String {
        if head.starts(with: [0x1f, 0x8b]) {
            return MediaTypes.imageLayerGzip
        }
        if head.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            return MediaTypes.imageLayerZstd
        }
        return MediaTypes.imageLayer
    }

    /// Hard-link a file into the layout under its digest. A blob two entries share
    /// is linked once. Whatever the archive itself put at that name is replaced:
    /// only the hash says what a blob holds.
    private static func link(_ file: URL, as digest: SHA256.Digest, into blobs: URL) throws {
        let destination = blobs.appendingPathComponent(digest.encoded)
        guard destination.path != file.path else {
            return
        }
        var st = stat()
        if lstat(destination.path, &st) == 0 {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.linkItem(at: file, to: destination)
    }

    /// Create `blobs/sha256` under the archive, refusing one the archive made a
    /// symlink: the layout has to stay inside the directory that is deleted after
    /// the load.
    private static func blobsDirectory(in root: URL) throws -> URL {
        let blobs = root.appendingPathComponent(Self.blobsDirectoryName)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        guard blobs.resolvingSymlinksInPath().path == blobs.path else {
            throw ContainerizationError(.invalidArgument, message: "\(Self.blobsDirectoryName) in the archive is a symbolic link")
        }
        return blobs
    }

    /// Resolve a path from `manifest.json` to a regular file inside the archive.
    ///
    /// The extractor vetted only the members' own paths, a symlink member may point
    /// anywhere, and the manifest is as untrusted as the rest of the archive. Without
    /// this, a manifest naming `../x` or `link/x` would hash a file outside the
    /// archive and link it into the store.
    private static func memberFile(_ member: String, in root: URL) throws -> URL {
        let prefix = root.path + "/"
        let candidate = root.appendingPathComponent(member).standardizedFileURL
        guard !member.isEmpty, candidate.path.hasPrefix(prefix) else {
            throw ContainerizationError(.invalidArgument, message: "\(member) is outside the archive")
        }
        let resolved = candidate.resolvingSymlinksInPath()
        var st = stat()
        guard lstat(resolved.path, &st) == 0 else {
            throw ContainerizationError(.notFound, message: "\(member) is not in the archive")
        }
        guard resolved.path.hasPrefix(prefix), (st.st_mode & S_IFMT) == S_IFREG else {
            throw ContainerizationError(.invalidArgument, message: "\(member) is not a regular file inside the archive")
        }
        return resolved
    }

    // MARK: Saving

    /// Write `manifest.json` and `repositories` beside the layout `ImageStore.save`
    /// left in `directory`, so that a classic `docker load` accepts the archive; a
    /// containerd-backed one reads the layout and ignores both files. An image
    /// saved for more than one platform has no single config to name and is left
    /// out, and one whose only name is a digest gets no `RepoTags`, since
    /// `docker load` refuses a digest where it expects a tag.
    func writeCompatibilityFiles(in directory: URL) throws {
        let index: Index = try Self.decode(controlFile: directory.appendingPathComponent(Self.indexFileName))
        let blobs = directory.appendingPathComponent(Self.blobsDirectoryName)

        var entries: [ManifestEntry] = []
        var repositories: [String: [String: String]] = [:]
        for descriptor in index.manifests {
            let name = Self.imageName(of: descriptor)
            guard let manifest = try self.singleManifest(for: descriptor, name: name, blobs: blobs) else {
                continue
            }
            let config = try Self.blobPath(manifest.config)
            let layers = try manifest.layers.map(Self.blobPath)
            var entry = ManifestEntry(config: config, repoTags: nil, layers: layers)
            if let name, let reference = try? Reference.parse(name), let tag = reference.tag {
                entry.repoTags = [name]
                let top = manifest.layers.last ?? manifest.config
                repositories[reference.name, default: [:]][tag] = try top.digest.validatedDigestEncoding()
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else {
            self.log.info("no image in the layout suits docker load, leaving out \(Self.manifestFileName)")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: directory.appendingPathComponent(Self.manifestFileName))
        try encoder.encode(repositories).write(to: directory.appendingPathComponent(Self.repositoriesFileName))
    }

    /// The image manifest an index entry stands for, or nil with a log line when
    /// it stands for several platforms.
    private func singleManifest(for descriptor: Descriptor, name: String?, blobs: URL) throws -> Manifest? {
        var current = descriptor
        while true {
            switch current.mediaType {
            case MediaTypes.imageManifest, MediaTypes.dockerManifest:
                return try Self.decode(blob: current, in: blobs)
            case MediaTypes.index, MediaTypes.dockerManifestList:
                let index: Index = try Self.decode(blob: current, in: blobs)
                // Attestation manifests describe no platform that could be loaded.
                let images = index.manifests.filter { $0.platform?.os != "unknown" }
                guard images.count == 1, let image = images.first else {
                    self.log.info(
                        "leaving an image out of \(Self.manifestFileName): docker load takes one platform",
                        metadata: ["image": "\(name ?? current.digest)", "platforms": "\(images.count)"])
                    return nil
                }
                current = image
            default:
                self.log.info(
                    "leaving an image out of \(Self.manifestFileName): not an image manifest",
                    metadata: ["image": "\(name ?? current.digest)", "mediaType": "\(current.mediaType)"])
                return nil
            }
        }
    }

    /// The name the loader would give the entry, in the loader's order of preference.
    private static func imageName(of descriptor: Descriptor) -> String? {
        guard let annotations = descriptor.annotations else {
            return nil
        }
        return annotations[AnnotationKeys.containerizationImageName]
            ?? annotations[AnnotationKeys.containerdImageName]
            ?? annotations[AnnotationKeys.openContainersImageName]
    }

    private static func blobPath(_ descriptor: Descriptor) throws -> String {
        let encoded = try descriptor.digest.validatedDigestEncoding()
        return "\(Self.blobsDirectoryName)/\(encoded)"
    }

    private static func decode<T: Decodable>(blob descriptor: Descriptor, in blobs: URL) throws -> T {
        let path = try ParsedDigest(parsing: descriptor.digest).path(in: blobs)
        return try Self.decode(controlFile: path)
    }

    /// Decode one of the archive's JSON files, refusing a symlink and anything
    /// larger than the content store lets a manifest be: a crafted archive must not
    /// be able to have the helper read gigabytes into memory.
    private static func decode<T: Decodable>(controlFile file: URL) throws -> T {
        do {
            let content = try LocalContent(path: file)
            return try content.decode()
        } catch {
            throw ContainerizationError(.invalidArgument, message: "cannot read \(file.lastPathComponent)", cause: error)
        }
    }
}
