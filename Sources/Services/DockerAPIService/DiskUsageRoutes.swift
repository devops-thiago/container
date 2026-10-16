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

/// What the engine says about the disk its images use, beyond what the image routes already
/// read. The agent answers it from the images service; tests answer it from a fake.
public protocol EngineDiskUsage: Sendable {
    /// What the images' content and unpacked snapshots take on disk, together.
    func layersSize() async throws -> Int64
}

/// A volume's usage, as only `GET /system/df` reports it.
public struct DockerVolumeUsage: Encodable, Sendable, Equatable {
    public var Size: Int64
    public var RefCount: Int64
}

/// `GET /system/df`.
public struct DockerDiskUsage: Encodable, Sendable {
    public var LayersSize: Int64
    public var Images: [DockerImageSummary]?
    public var Containers: [DockerContainerSummary]?
    public var Volumes: [DockerVolume]?
    public var BuildCache: [DockerEmptyObject]?
}

/// `GET /system/df?type=`: the images, containers and volumes, with what each takes on disk.
public enum DiskUsageRoutes {
    static let types: Set<String> = ["container", "image", "volume", "build-cache"]

    public static func register(
        on router: inout DockerRouter, disk: some EngineDiskUsage, images: some EngineImages, containers: some EngineContainers,
        volumes: some EngineVolumes, identities: DockerIdentityStore, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        router.add(.GET, "/system/df") { request, _ in
            try await usage(request, disk: disk, images: images, containers: containers, volumes: volumes, identities: identities, now: now)
        }
    }

    /// Each kind asked for, as dockerd answers: every kind without `type`, else only those
    /// named. Each size is one the Docker CLI can add up into a reclaimable figure no larger
    /// than dockerd's for the same objects:
    /// - an image's `SharedSize` is what of its content another image uses too, so an unused
    ///   image's `Size - SharedSize` is what removing it frees;
    /// - a container's `SizeRw` is what it wrote (`EngineContainers.writableSize`), left out
    ///   when the engine cannot tell;
    /// - a volume's `Size` is the bytes of its files (`EngineVolumes.dataSize`), -1 when the
    ///   engine cannot tell;
    /// - there is no build cache here (see `BuildRoutes`).
    static func usage(
        _ request: DockerRequest, disk: some EngineDiskUsage, images: some EngineImages, containers: some EngineContainers,
        volumes: some EngineVolumes, identities: DockerIdentityStore, now: @Sendable () -> Date
    ) async throws -> DockerResponse {
        let asked = request.query["type"] ?? []
        for type in asked where !types.contains(type) {
            throw DockerAPIError.badRequest("unknown object type: \(type)")
        }
        let wants = { (type: String) in asked.isEmpty || asked.contains(type) }
        let all = await identities.join(try await containers.list())

        var answer = DockerDiskUsage(LayersSize: 0, Images: nil, Containers: nil, Volumes: nil, BuildCache: nil)
        if wants("image") {
            answer.LayersSize = try await disk.layersSize()
            let records = try await images.list()
            let shared = DockerImageCatalog.sharedSizes(records)
            answer.Images = DockerImageCatalog(records).images.map { image in
                var summary = ImageViewMapper.summary(image, manifests: false, containers: [])
                summary.Containers = Int64(DockerImageCatalog.containers(using: image, among: all).count)
                summary.SharedSize = shared[image.id] ?? 0
                return summary
            }
        }
        if wants("container") {
            let context = DockerViewContext(
                now: now(), builtinNetwork: try await containers.builtinNetwork(), imageIDs: (try? await containers.imageIDs()) ?? [:])
            var summaries: [DockerContainerSummary] = []
            for container in all {
                var summary = ContainerViewMapper.summary(container, context: context)
                summary.SizeRw = ContainerViewMapper.listedSize(await containers.writableSize(container.snapshot))
                summaries.append(summary)
            }
            answer.Containers = summaries
        }
        if wants("volume") {
            let users = VolumeMapper.users(all)
            var shown: [DockerVolume] = []
            for volume in try await volumes.list().sorted(by: { $0.name < $1.name }) {
                var docker = VolumeMapper.volume(volume)
                // -1 is dockerd's "not computed", for a volume the engine could not measure.
                let size = (try? await volumes.dataSize(volume.name)).map { Int64(clamping: $0) } ?? -1
                docker.UsageData = DockerVolumeUsage(Size: size, RefCount: Int64(users[volume.name]?.count ?? 0))
                shown.append(docker)
            }
            answer.Volumes = shown
        }
        if wants("build-cache") {
            answer.BuildCache = []
        }
        return try .json(answer)
    }
}
