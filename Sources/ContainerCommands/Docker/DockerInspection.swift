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
import ContainerResource
import ContainerizationError
import DockerAPIEngine
import DockerAPIService
import Foundation

/// The kinds of object `docker inspect --type` names that this engine has.
public enum DockerObjectType: String, CaseIterable, ExpressibleByArgument, Sendable {
    case container
    case image
    case volume
}

/// `docker inspect`: containers, images and volumes as the Docker API shows them, through the
/// same views. A container's `Id` is its ID here, which every `container` command takes.
enum DockerInspection {
    /// One object found, ready to print.
    struct Found {
        let value: any Encodable & Sendable
    }

    /// The objects `names` name, in their order, and the names that found nothing.
    static func lookup(_ names: [String], type: DockerObjectType?) async throws -> (found: [Found], missing: [String]) {
        var found: [Found] = []
        var missing: [String] = []
        let kinds: [DockerObjectType] = type.map { [$0] } ?? [.container, .image, .volume]
        var containers: [String: DockerContainerInspect]?
        var catalog: DockerImageCatalog?
        for name in names {
            var hit: Found?
            for kind in kinds where hit == nil {
                switch kind {
                case .container:
                    if containers == nil { containers = try await Self.containers() }
                    hit = Self.container(name, in: containers ?? [:]).map(Found.init)
                case .image:
                    if catalog == nil { catalog = try await Self.catalog() }
                    hit = try catalog.flatMap { try Self.image(name, in: $0) }.map(Found.init)
                case .volume:
                    hit = try await Self.volume(name).map(Found.init)
                }
            }
            if let hit { found.append(hit) } else { missing.append(name) }
        }
        return (found, missing)
    }

    /// What Docker says when nothing has the name.
    static func notFound(_ name: String, type: DockerObjectType?) -> String {
        switch type {
        case .container: "No such container: \(name)"
        case .image: "No such image: \(name)"
        case .volume: "No such volume: \(name)"
        case nil: "No such object: \(name)"
        }
    }

    // MARK: Containers

    /// Every container but the engine's own, by ID.
    static func containers() async throws -> [String: DockerContainerInspect] {
        let snapshots = try await ContainerClient().list(filters: ContainerListFilters.all.withoutInfrastructure())
        let context = DockerViewContext(
            now: Date(), builtinNetwork: try? await NetworkClient().builtin?.id,
            imageIDs: (try? await EngineImageRecords.imageIDs(digests: Set(snapshots.map(\.configuration.image.digest)))) ?? [:])
        return views(snapshots, context: context)
    }

    /// Each container's Docker view, by its ID here.
    static func views(_ snapshots: [ContainerSnapshot], context: DockerViewContext) -> [String: DockerContainerInspect] {
        Dictionary(
            snapshots.map { ($0.id, ContainerViewMapper.inspect(dockerContainer($0), context: context)) }, uniquingKeysWith: { first, _ in first })
    }

    /// A container as the Docker views take it, under its ID here.
    static func dockerContainer(_ snapshot: ContainerSnapshot) -> DockerContainer {
        DockerContainer(snapshot: snapshot, dockerID: snapshot.id, name: DockerIdentityTable.engineName(snapshot))
    }

    /// The container `name` names, as dockerd finds one: by ID, by name, then by a prefix of
    /// one ID only.
    static func container(_ name: String, in containers: [String: DockerContainerInspect]) -> DockerContainerInspect? {
        if let exact = containers[name] { return exact }
        let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let named = containers.values.first(where: { $0.Name == "/" + bare }) { return named }
        let prefixed = containers.filter { $0.key.hasPrefix(name) }
        return prefixed.count == 1 ? prefixed.first?.value : nil
    }

    // MARK: Images

    /// The engine's images but its own, grouped by ID as Docker lists them.
    static func catalog() async throws -> DockerImageCatalog {
        let system = try await Application.loadContainerSystemConfig()
        return DockerImageCatalog(try await EngineImageRecords.list(builderImage: system.build.image, initImage: system.vminit.image))
    }

    /// The image `name` names, as dockerd finds one: by ID, by reference, then by a prefix of
    /// one ID only.
    static func image(_ name: String, in catalog: DockerImageCatalog) throws -> DockerImageInspect? {
        do {
            return ImageViewMapper.inspect(try catalog.resolve(name).image)
        } catch  where error.status.code == 404 {
            return nil
        } catch {
            throw ValidationError(error.message)
        }
    }

    // MARK: Volumes

    static func volume(_ name: String) async throws -> DockerVolume? {
        do {
            return VolumeMapper.volume(try await ClientVolume.inspect(name))
        } catch let error as VolumeError {
            guard case .volumeNotFound = error else { throw error }
            return nil
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return nil
        }
    }

    // MARK: Output

    /// Each object through `template`, a line each; or, without one, a JSON array of them.
    static func render(_ found: [Found], template: DockerTemplate?) throws -> String {
        if let template {
            return try found.map { try template.render(AnyEncodable($0.value)) }.joined(separator: "\n")
        }
        return try Output.renderJSON(found.map { AnyEncodable($0.value) }, options: JSONOptions(outputFormatting: [.prettyPrinted]))
    }
}

/// An `Encodable` of any type, so that objects of several kinds go in one array.
struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }
}
