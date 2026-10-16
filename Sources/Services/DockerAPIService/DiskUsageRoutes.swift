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

/// What the engine says about the disk it uses, beyond what the image, container and volume
/// routes already read. The agent answers it from the API server and the images service;
/// tests answer it from a fake.
public protocol EngineDiskUsage: Sendable {
    /// What the images' content and unpacked snapshots take on disk, together.
    func layersSize() async throws -> Int64
    /// What a container's own directory takes on disk, or nil when the engine cannot say.
    func containerSize(_ engineID: String) async throws -> Int64?
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
    /// named. `SizeRw` is what the container's directory in the engine takes, which holds its
    /// writable filesystem; `SharedSize` is not computed (-1). There is no build cache here.
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
            answer.Images = DockerImageCatalog(try await images.list()).images.map { image in
                var summary = ImageViewMapper.summary(image, manifests: false, containers: [])
                summary.Containers = Int64(DockerImageCatalog.containers(using: image, among: all).count)
                return summary
            }
        }
        if wants("container") {
            let context = DockerViewContext(
                now: now(), builtinNetwork: try await containers.builtinNetwork(), imageIDs: (try? await containers.imageIDs()) ?? [:])
            var summaries: [DockerContainerSummary] = []
            for container in all {
                var summary = ContainerViewMapper.summary(container, context: context)
                summary.SizeRw = (try? await disk.containerSize(container.engineID)) ?? nil
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
                let size = (try? await volumes.diskUsage(volume.name)).map { Int64(clamping: $0) } ?? -1
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
