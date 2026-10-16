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

/// The `filters`, `all` and `limit` of `GET /containers/json`, applied as dockerd applies them.
///
/// Values of one filter are alternatives; different filters must all hold. `id`, `name` and
/// `status` are unanchored regular expressions, as dockerd matches them, so an ID filter is in
/// effect a prefix. `label` is `key` or `key=value`, every one required. A `status` filter, or a
/// `limit`, lists stopped containers without `all`.
public struct ContainerListFilter: Sendable {
    /// The filters this service implements.
    public static let supported: Set<String> = ["id", "name", "label", "status", "ancestor", "network", "volume", "exited", "health"]
    /// Filters dockerd has that this service does not, refused rather than ignored.
    static let unsupported: Set<String> = ["before", "since", "publish", "expose", "is-task", "isolation", "annotation"]

    let filters: [String: [String]]
    let all: Bool
    let limit: Int
    let exitCodes: [Int32]
    let context: DockerViewContext

    public init(filters: [String: [String]], all: Bool, limit: Int?, context: DockerViewContext) throws(DockerAPIError) {
        for key in filters.keys.sorted() where !Self.supported.contains(key) {
            if Self.unsupported.contains(key) {
                throw .badRequest("the '\(key)' filter is not supported")
            }
            throw .badRequest("invalid filter '\(key)'")
        }
        for value in filters["status"] ?? [] where DockerContainerStatus(rawValue: value) == nil {
            throw .badRequest(
                "invalid filter 'status=\(value)': invalid value for state (\(value)): must be one of "
                    + DockerContainerStatus.allCases.map(\.rawValue).joined(separator: ", "))
        }
        for value in filters["health"] ?? [] where !["starting", "healthy", "unhealthy", "none"].contains(value) {
            throw .badRequest("invalid filter 'health=\(value)'")
        }
        var codes: [Int32] = []
        for value in filters["exited"] ?? [] {
            guard let code = Int32(value) else { throw .badRequest("invalid filter 'exited=\(value)'") }
            codes.append(code)
        }
        for value in (filters["id"] ?? []) + (filters["name"] ?? []) where (try? Regex(value)) == nil {
            throw .badRequest("invalid filter value: \(value)")
        }
        self.filters = filters
        self.all = all || filters["status"] != nil
        self.limit = limit ?? 0
        self.exitCodes = codes
        self.context = context
    }

    /// The containers the request lists, newest first.
    public func apply(_ containers: [DockerContainer]) -> [DockerContainer] {
        let sorted = containers.sorted { $0.snapshot.configuration.creationDate > $1.snapshot.configuration.creationDate }
        var listed: [DockerContainer] = []
        for container in sorted where matches(container) {
            if limit > 0 && listed.count == limit { break }
            listed.append(container)
        }
        return listed
    }

    public func matches(_ container: DockerContainer) -> Bool {
        let snapshot = container.snapshot
        let status = ContainerViewMapper.status(snapshot)
        if !ContainerViewMapper.isRunning(snapshot) && !all && limit <= 0 {
            return false
        }
        return matchesPattern("id", container.dockerID)
            && (matchesPattern("name", container.name) || matchesPattern("name", "/" + container.name))
            && matchesLabels(snapshot.configuration.labels)
            && matchesExitCode(snapshot, status: status)
            && matchesPattern("status", status.rawValue)
            && matchesExact("health", snapshot.health?.status.rawValue ?? (snapshot.configuration.healthCheck == nil ? "none" : "starting"))
            && matchesVolume(snapshot.configuration)
            && matchesAncestor(container)
            && matchesNetwork(container)
    }

    /// True without the filter; otherwise true when any value, as a regular expression, is
    /// found in `text`.
    private func matchesPattern(_ key: String, _ text: String) -> Bool {
        guard let values = filters[key] else { return true }
        return values.contains { value in
            value == text || ((try? Regex(value)).map { text.contains($0) } ?? false)
        }
    }

    private func matchesExact(_ key: String, _ text: String) -> Bool {
        guard let values = filters[key] else { return true }
        return values.contains(text)
    }

    private func matchesLabels(_ labels: [String: String]) -> Bool {
        (filters["label"] ?? []).allSatisfy { condition in
            let parts = condition.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let value = labels[String(parts[0])] else { return false }
            return parts.count == 1 || value == parts[1]
        }
    }

    /// dockerd matches an exit code only for a container that ran and stopped.
    private func matchesExitCode(_ snapshot: ContainerSnapshot, status: DockerContainerStatus) -> Bool {
        guard !exitCodes.isEmpty else { return true }
        guard status == .exited, let code = snapshot.exitCode else { return false }
        return exitCodes.contains(code)
    }

    /// A volume's name or a mount's destination; a bind's source stands for its name.
    private func matchesVolume(_ configuration: ContainerConfiguration) -> Bool {
        guard let values = filters["volume"] else { return true }
        return configuration.mounts.contains { mount in
            values.contains(mount.destination) || values.contains(mount.volumeName ?? mount.source)
        }
    }

    /// The image by the name the client used, its normalized reference with or without
    /// `:latest`, or its ID or a prefix of it. dockerd also matches images built on the named
    /// one; image history is not known here.
    private func matchesAncestor(_ container: DockerContainer) -> Bool {
        guard let values = filters["ancestor"] else { return true }
        let reference = container.snapshot.configuration.image.reference
        let id = ContainerViewMapper.imageID(container, context: context)
        let shortID = id.split(separator: ":").last.map(String.init) ?? id
        var names: Set<String> = [reference, ContainerViewMapper.image(container)]
        for name in names where name.hasSuffix(":latest") {
            names.insert(String(name.dropLast(":latest".count)))
        }
        if reference.hasPrefix("docker.io/library/") {
            let familiar = String(reference.dropFirst("docker.io/library/".count))
            names.insert(familiar)
            if familiar.hasSuffix(":latest") { names.insert(String(familiar.dropLast(":latest".count))) }
        }
        return values.contains { value in
            names.contains(value) || id == value || (value.count >= 4 && (shortID.hasPrefix(value) || id.hasPrefix(value)))
        }
    }

    /// A network by its Docker name or a prefix of its ID.
    private func matchesNetwork(_ container: DockerContainer) -> Bool {
        guard let values = filters["network"] else { return true }
        let networks = ContainerViewMapper.networks(container, context: context)
        return values.contains { value in
            networks[value] != nil || networks.values.contains { $0.NetworkID.hasPrefix(value) }
        }
    }
}
