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

/// One image in `GET /images/json`.
public struct DockerImageSummary: Encodable, Sendable, Equatable {
    public var Id: String
    public var ParentId: String
    public var RepoTags: [String]
    public var RepoDigests: [String]
    public var Created: Int64
    public var Size: Int64
    /// -1: not computed, as dockerd answers without `shared-size`.
    public var SharedSize: Int64
    public var Labels: [String: String]
    /// -1 below API 1.51, as dockerd answers.
    public var Containers: Int64
    /// Only with `manifests=1`.
    public var Manifests: [DockerImageManifestSummary]?
    public var Descriptor: DockerDescriptor
}

/// One entry of an image's index, as `manifests=1` lists it. The CLI's default image list
/// (a tree since 29.0) reads `Kind`, `Size.Content` and `ImageData.Containers` from it.
public struct DockerImageManifestSummary: Encodable, Sendable, Equatable {
    public struct SizeBody: Encodable, Sendable, Equatable {
        public var Total: Int64
        public var Content: Int64
    }

    public struct PlatformBody: Encodable, Sendable, Equatable {
        public var architecture: String
        public var os: String
        public var variant: String?
    }

    public struct ImageDataBody: Encodable, Sendable, Equatable {
        public struct Unpacked: Encodable, Sendable, Equatable { public var Unpacked: Int64 }
        public var Platform: PlatformBody
        public var Containers: [String]
        public var Size: Unpacked
    }

    public struct AttestationDataBody: Encodable, Sendable, Equatable {
        public var For: String
    }

    public var ID: String
    public var Descriptor: DockerDescriptor
    public var Available: Bool
    public var Size: SizeBody
    public var Kind: String
    public var ImageData: ImageDataBody?
    public var AttestationData: AttestationDataBody?
}

/// `GET /images/{name}/json`, with the fields API 1.48 always carries.
public struct DockerImageInspect: Encodable, Sendable, Equatable {
    public struct GraphDriverBody: Encodable, Sendable, Equatable {
        public var Data: [String: String]
        public var Name: String
    }

    public struct RootFSBody: Encodable, Sendable, Equatable {
        public var `Type`: String
        public var Layers: [String]
    }

    public struct MetadataBody: Encodable, Sendable, Equatable {
        public var LastTagTime: String
    }

    public var Id: String
    public var RepoTags: [String]
    public var RepoDigests: [String]
    public var Parent: String
    public var Comment: String
    public var Created: String?
    public var DockerVersion: String
    public var Author: String
    public var Config: DockerImageConfigView
    public var Architecture: String
    public var Variant: String?
    public var Os: String
    public var OsVersion: String?
    public var Size: Int64
    public var GraphDriver: GraphDriverBody
    public var RootFS: RootFSBody
    public var Metadata: MetadataBody
    public var Descriptor: DockerDescriptor
}

/// An image's `Config` as API 1.48 shows it: the fields dockerd always wrote below 1.50, as
/// `null` or zero when the image does not set them, and the optional ones only when set.
public struct DockerImageConfigView: Encodable, Sendable, Equatable {
    public var config: DockerImageConfigDocument.Config

    enum CodingKeys: String, CodingKey {
        case Hostname, Domainname, User, AttachStdin, AttachStdout, AttachStderr, ExposedPorts, Tty, OpenStdin, StdinOnce, Env, Cmd
        case Healthcheck, ArgsEscaped, Image, Volumes, WorkingDir, Entrypoint, OnBuild, Labels, StopSignal, Shell
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("", forKey: .Hostname)
        try c.encode("", forKey: .Domainname)
        try c.encode(config.User ?? "", forKey: .User)
        try c.encode(false, forKey: .AttachStdin)
        try c.encode(false, forKey: .AttachStdout)
        try c.encode(false, forKey: .AttachStderr)
        try c.encodeIfPresent(config.ExposedPorts, forKey: .ExposedPorts)
        try c.encode(false, forKey: .Tty)
        try c.encode(false, forKey: .OpenStdin)
        try c.encode(false, forKey: .StdinOnce)
        // `encode` of an optional writes `null`, as dockerd does for these.
        try c.encode(config.Env, forKey: .Env)
        try c.encode(config.Cmd, forKey: .Cmd)
        try c.encodeIfPresent(config.Healthcheck, forKey: .Healthcheck)
        try c.encodeIfPresent(config.ArgsEscaped, forKey: .ArgsEscaped)
        try c.encode("", forKey: .Image)
        try c.encode(config.Volumes, forKey: .Volumes)
        try c.encode(config.WorkingDir ?? "", forKey: .WorkingDir)
        try c.encode(config.Entrypoint, forKey: .Entrypoint)
        try c.encode(config.OnBuild, forKey: .OnBuild)
        try c.encode(config.Labels, forKey: .Labels)
        try c.encodeIfPresent(config.StopSignal, forKey: .StopSignal)
        try c.encodeIfPresent(config.Shell, forKey: .Shell)
    }
}

/// One layer of `GET /images/{name}/history`, newest first.
public struct DockerImageHistoryItem: Encodable, Sendable, Equatable {
    public var Id: String
    public var Created: Int64
    public var CreatedBy: String
    public var Tags: [String]?
    public var Size: Int64
    public var Comment: String

    enum CodingKeys: String, CodingKey { case Id, Created, CreatedBy, Tags, Size, Comment }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Id, forKey: .Id)
        try c.encode(Created, forKey: .Created)
        try c.encode(CreatedBy, forKey: .CreatedBy)
        // `null` below the top layer, as dockerd writes it.
        try c.encode(Tags, forKey: .Tags)
        try c.encode(Size, forKey: .Size)
        try c.encode(Comment, forKey: .Comment)
    }
}

/// One line of `DELETE /images/{name}` and of a prune's `ImagesDeleted`.
public struct DockerImageDeleteItem: Encodable, Sendable, Equatable {
    public var Untagged: String?
    public var Deleted: String?

    public static func untagged(_ reference: String) -> Self { Self(Untagged: reference, Deleted: nil) }
    public static func deleted(_ id: String) -> Self { Self(Untagged: nil, Deleted: id) }
}

public struct DockerImagePruneReport: Encodable, Sendable, Equatable {
    public var ImagesDeleted: [DockerImageDeleteItem]?
    public var SpaceReclaimed: UInt64
}

/// The engine's images in Docker's shapes.
public enum ImageViewMapper {
    static func unix(_ date: Date?) -> Int64 {
        date.map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    public static func summary(_ image: DockerImage, manifests: Bool, containers: [DockerContainer]) -> DockerImageSummary {
        let primary = image.primary
        return DockerImageSummary(
            Id: image.id,
            ParentId: "",
            RepoTags: image.repoTags,
            RepoDigests: image.repoDigests,
            Created: unix(image.created),
            Size: primary.size,
            SharedSize: -1,
            Labels: image.labels,
            Containers: -1,
            Manifests: manifests ? manifestSummaries(image, containers: containers) : nil,
            Descriptor: primary.target)
    }

    static func manifestSummaries(_ image: DockerImage, containers: [DockerContainer]) -> [DockerImageManifestSummary] {
        // A container is counted under the host's manifest, which is what it runs.
        let users = DockerImageCatalog.containers(using: image, among: containers).map(\.dockerID)
        let hostDigest = image.primary.manifestDigest
        return image.primary.manifests.map { manifest in
            DockerImageManifestSummary(
                ID: manifest.descriptor.digest,
                Descriptor: manifest.descriptor,
                Available: manifest.available,
                Size: .init(Total: manifest.contentSize, Content: manifest.contentSize),
                Kind: manifest.kind.rawValue,
                ImageData: manifest.platform.map { platform in
                    .init(
                        Platform: .init(architecture: platform.architecture, os: platform.os, variant: platform.variant),
                        Containers: manifest.descriptor.digest == hostDigest ? users : [], Size: .init(Unpacked: 0))
                },
                AttestationData: manifest.attestationFor.map { .init(For: $0) })
        }
    }

    public static func inspect(_ image: DockerImage) -> DockerImageInspect {
        let primary = image.primary
        let config = primary.config
        return DockerImageInspect(
            Id: image.id,
            RepoTags: image.repoTags,
            RepoDigests: image.repoDigests,
            Parent: "",
            Comment: "",
            Created: image.created.map(ContainerViewMapper.timestamp),
            DockerVersion: "",
            Author: config?.author ?? "",
            Config: DockerImageConfigView(config: config?.config ?? .init()),
            Architecture: config?.architecture ?? "",
            Variant: config?.variant,
            Os: config?.os ?? "",
            OsVersion: config?.osVersion,
            Size: primary.size,
            GraphDriver: .init(Data: [:], Name: "virtiofs"),
            RootFS: .init(Type: config?.rootfs?.type ?? "layers", Layers: config?.rootfs?.diffIDs ?? []),
            Metadata: .init(LastTagTime: ContainerViewMapper.zeroTime),
            Descriptor: primary.target)
    }

    /// The config's history, newest first. A layer's size is that of the next layer in the
    /// manifest; an empty layer's is 0. Only the newest entry carries the ID and tags; the rest
    /// are `<missing>`, as for any image dockerd did not build itself.
    public static func history(_ image: DockerImage) -> [DockerImageHistoryItem] {
        let primary = image.primary
        var sizes = primary.layerSizes.makeIterator()
        var items = (primary.config?.history ?? []).map { entry in
            DockerImageHistoryItem(
                Id: "<missing>",
                Created: unix(entry.created.flatMap(DockerImageConfigDocument.parseTime)),
                CreatedBy: entry.createdBy ?? "",
                Tags: nil,
                Size: entry.emptyLayer == true ? 0 : (sizes.next() ?? 0),
                Comment: entry.comment ?? "")
        }
        items.reverse()
        if !items.isEmpty {
            items[0].Id = image.id
            items[0].Tags = image.repoTags
        }
        return items
    }
}
