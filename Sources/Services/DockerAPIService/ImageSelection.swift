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

/// The `filters` of `GET /images/json`, applied as dockerd applies them.
///
/// `reference` is a glob (`path.Match`) over each reference's familiar and full forms, with
/// and without its tag; a reference that does not match is left out of the image's tags and
/// digests, and an image with none left is not listed. `before` and `since` name an image and
/// compare creation times. `label` needs every `key` or `key=value`.
public struct ImageListFilter: Sendable {
    static let accepted: Set<String> = ["dangling", "label", "before", "since", "reference"]
    static let unsupported: Set<String> = ["until"]

    let filters: [String: [String]]
    let dangling: Bool?
    let before: Date?
    let since: Date?

    public init(filters: [String: [String]], catalog: DockerImageCatalog) throws(DockerAPIError) {
        try DockerFilters.validate(filters, accepted: Self.accepted, unsupported: Self.unsupported)
        dangling = filters["dangling"] == nil ? nil : try DockerFilters.bool(filters, "dangling", default: false)
        var before: Date?
        for term in filters["before"] ?? [] {
            if let created = try catalog.resolve(term).image.created, before.map({ created < $0 }) ?? true { before = created }
        }
        var since: Date?
        for term in filters["since"] ?? [] {
            if let created = try catalog.resolve(term).image.created, since.map({ created > $0 }) ?? true { since = created }
        }
        for pattern in filters["reference"] ?? [] {
            do {
                _ = try DockerFilters.glob(pattern, "")
            } catch {
                throw .badRequest("syntax error in pattern: \(pattern)")
            }
        }
        self.filters = filters
        self.before = before
        self.since = since
    }

    /// The images the request lists, newest first, each with only the references it matched.
    public func apply(_ catalog: DockerImageCatalog) -> [DockerImage] {
        catalog.images.compactMap { image in
            if let before, !(image.created.map { $0 < before } ?? false) { return nil }
            if let since, !(image.created.map { $0 > since } ?? false) { return nil }
            if filters["label"] != nil && !DockerFilters.labelsMatch(filters["label"], image.labels) { return nil }
            if let dangling, dangling != image.isDangling { return nil }
            guard let patterns = filters["reference"] else { return image }
            let records = image.records.filter { record in
                patterns.contains { pattern in Self.targets(record).contains { (try? DockerFilters.glob(pattern, $0)) == true } }
            }
            return records.isEmpty ? nil : DockerImage(id: image.id, records: records)
        }
    }

    /// What a `reference` pattern is matched against: `alpine:3`, `alpine`,
    /// `docker.io/library/alpine:3` and `docker.io/library/alpine`.
    static func targets(_ record: EngineImageRecord) -> [String] {
        // The reserved reference of an image with no name is not one a pattern can match.
        guard !record.isDanglingMarker else { return [] }
        guard let parsed = record.parsed else { return [record.reference] }
        return [parsed.familiar, parsed.familiarName, parsed.normalized, parsed.name]
    }
}

/// What deleting an image or pruning does: which of the engine's references go, and the lines
/// that tell the client, decided as dockerd's containerd image store decides them.
public enum ImageDeletion {
    public struct Plan: Sendable, Equatable {
        /// The engine references to delete, in order.
        public var remove: [EngineImageRecord]
        public var items: [DockerImageDeleteItem]
    }

    /// `DELETE /images/{name}?force=`.
    ///
    /// Named by a reference: that tag of its repository goes (with the repository's digest
    /// references when no other tag of it is left). Only when nothing else names the image is it
    /// deleted, and then not while a container uses it unless forced.
    ///
    /// Named by ID: every reference goes. A running container's image cannot be deleted even
    /// with `force`; a stopped container's, or one named in several repositories, needs it.
    public static func plan(_ match: DockerImageCatalog.Match, force: Bool, containers: [DockerContainer]) throws(DockerAPIError) -> Plan {
        let image = match.image
        // The reserved reference of an image with no name keeps nothing alive: it goes with the
        // image's last name.
        let all = image.records.filter { !$0.isDanglingMarker }
        let users = DockerImageCatalog.containers(using: image, among: containers)
        if let record = match.record, !record.isDanglingMarker {
            let same = sameReferences(record, in: all)
            if same.count < all.count {
                return Plan(remove: same, items: same.map { .untagged($0.familiarReference) })
            }
            if let user = users.first, !force {
                throw .conflict(
                    "conflict: unable to delete \(record.familiarReference) (must be forced) - container \(short(user.dockerID)) is using its referenced image \(image.shortID)"
                )
            }
            return everything(image)
        }
        if let running = users.first(where: { ContainerViewMapper.isRunning($0.snapshot) }) {
            throw .conflict("conflict: unable to delete \(image.shortID) (cannot be forced) - image is being used by running container \(short(running.dockerID))")
        }
        if !force {
            if let stopped = users.first {
                throw .conflict("conflict: unable to delete \(image.shortID) (must be forced) - image is being used by stopped container \(short(stopped.dockerID))")
            }
            if let first = all.first(where: \.isTagged) ?? all.first, sameReferences(first, in: all).count < all.count {
                throw .conflict("conflict: unable to delete \(image.shortID) (must be forced) - image is referenced in multiple repositories")
            }
        }
        return everything(image)
    }

    /// Every reference, then the image. The reserved reference of an image with no name goes
    /// unannounced, as dockerd reports such an image's delete with its ID alone.
    static func everything(_ image: DockerImage) -> Plan {
        Plan(
            remove: image.records,
            items: image.records.filter { !$0.isDanglingMarker }.map { .untagged($0.familiarReference) } + [.deleted(image.id)])
    }

    /// The references a name stands for among an image's: the same repository and tag, or,
    /// for a digest, every reference to the repository. A repository's digest references go
    /// with its last tag.
    static func sameReferences(_ record: EngineImageRecord, in all: [EngineImageRecord]) -> [EngineImageRecord] {
        guard let named = record.parsed else { return [record] }
        let repository = all.filter { $0.parsed?.name == named.name }
        guard let tag = named.tag else { return repository }
        let sameTag = repository.filter { $0.parsed?.tag == tag }
        let otherTags = repository.contains { $0.parsed?.tag != nil && $0.parsed?.tag != tag }
        return otherTags ? sameTag : sameTag + repository.filter { $0.parsed?.tag == nil }
    }

    static let pruneAccepted: Set<String> = ["dangling", "label", "label!"]

    /// The images `POST /images/prune` removes: the dangling ones (named by neither a tag nor
    /// a digest, so an image pulled by digest stays), or with `dangling=false` every one, that
    /// match the label filters and that no container uses, running or not.
    public static func pruneSelection(
        _ catalog: DockerImageCatalog, filters: [String: [String]], containers: [DockerContainer]
    ) throws(DockerAPIError) -> [DockerImage] {
        try DockerFilters.validate(filters, accepted: pruneAccepted, unsupported: ["until"])
        let danglingOnly = try DockerFilters.bool(filters, "dangling", default: true)
        return catalog.images.filter { image in
            (!danglingOnly || image.isDangling) && DockerFilters.pruneLabelsMatch(filters, image.labels)
                && DockerImageCatalog.containers(using: image, among: containers).isEmpty
        }
    }

    static func short(_ id: String) -> String {
        String(id.prefix(12))
    }
}
