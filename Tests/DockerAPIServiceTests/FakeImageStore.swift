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
import ContainerizationExtras
import Foundation
import Synchronization

@testable import DockerAPIService

/// Images, volumes and networks for the image, volume and network tests.
enum StoreFixtures {
    static func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    /// A reference to an image whose ID is `id` and whose index is `target`, created `created`
    /// seconds after the epoch, with `labels`.
    static func record(
        _ reference: String, id: Character, target: Character? = nil, created: Int = 1_700_000_000, labels: [String: String]? = nil,
        infrastructure: Bool = false
    ) -> EngineImageRecord {
        let date = Date(timeIntervalSince1970: TimeInterval(created))
        return EngineImageRecord(
            reference: reference,
            target: DockerDescriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: digest(target ?? id), size: 500),
            id: digest(id),
            size: 4_000_000,
            config: DockerImageConfigDocument(
                created: Date.ISO8601FormatStyle().format(date), architecture: "arm64", os: "linux",
                config: .init(Env: ["PATH=/bin"], Cmd: ["/bin/sh"], Labels: labels),
                rootfs: .init(diffIDs: [digest("1"), digest("2")]),
                history: [
                    .init(created: "2023-11-14T22:13:20Z", createdBy: "ADD rootfs.tar /"),
                    .init(created: "2023-11-14T22:13:20Z", createdBy: "ENV PATH=/bin", emptyLayer: true),
                    .init(created: "2023-11-14T22:13:21Z", createdBy: "RUN apk add curl", comment: "buildkit"),
                ]),
            layerSizes: [3_000_000, 900_000],
            manifests: [
                EngineImageManifest(
                    descriptor: DockerDescriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: digest("m"), size: 400),
                    kind: .image, platform: ("linux", "arm64", "v8"), available: true, contentSize: 3_900_400),
                EngineImageManifest(
                    descriptor: DockerDescriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: digest("n"), size: 400),
                    kind: .image, platform: ("linux", "amd64", nil), available: false, contentSize: 400),
                EngineImageManifest(
                    descriptor: DockerDescriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: digest("t"), size: 300),
                    kind: .attestation, platform: nil, available: true, contentSize: 900, attestationFor: digest("m")),
            ],
            manifestDigest: digest("m"),
            infrastructure: infrastructure)
    }

    enum Run {
        case created
        case running
        case exited
    }

    /// A container made from `image` (by its index digest and reference), as the engine records it.
    static func container(_ name: String, image: EngineImageRecord, run: Run = .created) -> ContainerSnapshot {
        var configuration = Fixtures.configuration(id: name)
        configuration.image = ImageDescription(
            reference: image.reference,
            descriptor: .init(mediaType: image.target.mediaType, digest: image.target.digest, size: image.target.size))
        switch run {
        case .created: return Fixtures.snapshot(configuration, status: .stopped, started: nil)
        case .running: return Fixtures.snapshot(configuration, status: .running)
        case .exited: return Fixtures.snapshot(configuration, status: .stopped, exitCode: 0, exited: Fixtures.now)
        }
    }
}

/// An images service in memory: references kept as records, with a log of what was asked.
final class FakeImageStore: EngineImages, Sendable {
    struct State {
        var records: [EngineImageRecord]
        var calls: [String] = []
        var saved: [String: Data] = [:]
        var loaded: [Data] = []
        var loadResult = DockerLoadedImages(references: [])
        var pushFailure: DockerAPIError?
        /// The credential each pull and push was given, in order.
        var credentials: [DockerRegistryCredential?] = []
    }

    let state: Mutex<State>

    init(_ records: [EngineImageRecord] = []) {
        state = Mutex(State(records: records))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var references: [String] { state.withLock { $0.records.map(\.reference).sorted() } }

    func pull(reference: String, platform: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws
        -> DockerPulledImage
    {
        state.withLock { $0.credentials.append(credential) }
        return DockerPulledImage(digest: StoreFixtures.digest("a"), updated: true)
    }

    var credentials: [DockerRegistryCredential?] { state.withLock { $0.credentials } }

    func list() async throws -> [EngineImageRecord] {
        state.withLock { $0.records }
    }

    func tag(_ source: String, as target: String) async throws {
        try state.withLock { state in
            guard var record = state.records.first(where: { $0.reference == source }) else {
                throw DockerAPIError.notFound("no \(source)")
            }
            state.calls.append("tag \(source) \(target)")
            state.records.removeAll { $0.reference == target }
            record.reference = target
            state.records.append(record)
        }
    }

    func delete(_ reference: String) async throws {
        state.withLock { state in
            state.calls.append("delete \(reference)")
            state.records.removeAll { $0.reference == reference }
        }
    }

    func collectGarbage() async throws -> UInt64 {
        state.withLock { $0.calls.append("gc") }
        return 1234
    }

    /// The record's target, as for a push of every platform; nil for a push of one.
    func push(reference: String, platform: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws
        -> DockerDescriptor?
    {
        let (failure, target) = state.withLock { state in
            state.calls.append("push \(reference)")
            state.credentials.append(credential)
            return (state.pushFailure, state.records.first { $0.reference == reference }?.target)
        }
        progress([.addTotalSize(100)])
        try await Task.sleep(for: .milliseconds(5))
        progress([.addSize(100)])
        if let failure { throw failure }
        return platform == nil ? target : nil
    }

    func save(references: [String], platform: String?, to file: URL) async throws {
        let data = Data(("archive of " + references.joined(separator: ",") + " for " + (platform ?? "host")).utf8)
        try data.write(to: file)
        state.withLock { $0.calls.append("save \(references.joined(separator: ",")) \(platform ?? "-")") }
    }

    func load(from file: URL) async throws -> DockerLoadedImages {
        let data = try Data(contentsOf: file)
        return state.withLock { state in
            state.loaded.append(data)
            state.calls.append("load \(data.count)")
            return state.loadResult
        }
    }
}

/// The volume service in memory.
final class FakeVolumes: EngineVolumes, Sendable {
    let state: Mutex<(volumes: [VolumeConfiguration], calls: [String])>
    /// Volumes the engine cannot measure, as one a running container has mounted.
    let unmeasured: Set<String>

    init(_ volumes: [VolumeConfiguration] = [], unmeasured: Set<String> = []) {
        state = Mutex((volumes, []))
        self.unmeasured = unmeasured
    }

    var calls: [String] { state.withLock { $0.calls } }
    var names: [String] { state.withLock { $0.volumes.map(\.name).sorted() } }

    static func volume(_ name: String, labels: [String: String] = [:], anonymous: Bool = false) -> VolumeConfiguration {
        var labels = labels
        if anonymous { labels[VolumeConfiguration.anonymousLabel] = "" }
        return VolumeConfiguration(
            name: name, source: "/volumes/\(name)/volume.img", creationDate: Date(timeIntervalSince1970: 1_700_000_000), labels: labels)
    }

    func list() async throws -> [VolumeConfiguration] {
        state.withLock { $0.volumes }
    }

    func create(name: String, driverOpts: [String: String], labels: [String: String]) async throws -> VolumeConfiguration {
        try state.withLock { state in
            guard !state.volumes.contains(where: { $0.name == name }) else { throw DockerAPIError.conflict("volume '\(name)' already exists") }
            let volume = VolumeConfiguration(
                name: name, source: "/volumes/\(name)/volume.img", creationDate: Date(timeIntervalSince1970: 1_700_000_000), labels: labels,
                options: driverOpts)
            state.volumes.append(volume)
            state.calls.append("create \(name)")
            return volume
        }
    }

    func delete(_ name: String, requiredLabels: [String: String]?) async throws {
        try state.withLock { state in
            guard let volume = state.volumes.first(where: { $0.name == name }) else { throw DockerAPIError.notFound("volume '\(name)' not found") }
            for (key, value) in requiredLabels ?? [:] where volume.labels[key] != value {
                throw DockerAPIError.badRequest("volume \(name) does not carry the labels this deletion requires")
            }
            state.volumes.removeAll { $0.name == name }
            state.calls.append("delete \(name) \(requiredLabels.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "-")")
        }
    }

    func dataSize(_ name: String) async throws -> UInt64? {
        unmeasured.contains(name) ? nil : 1000
    }
}

/// The network service in memory, with the builtin network.
final class FakeNetworks: EngineNetworks, Sendable {
    let state: Mutex<(networks: [NetworkResource], calls: [String])>

    init(_ networks: [NetworkResource] = []) {
        state = Mutex(([Self.builtin] + networks, []))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var names: [String] { state.withLock { $0.networks.map(\.id).sorted() } }

    static let builtin: NetworkResource = network(Fixtures.builtin, subnet: "192.168.64.0/24", builtin: true)

    static func network(_ name: String, subnet: String = "10.1.0.0/24", mode: NetworkMode = .nat, labels: [String: String] = [:], builtin: Bool = false)
        -> NetworkResource
    {
        var labels = labels
        if builtin { labels[ResourceLabelKeys.role] = ResourceRoleValues.builtin }
        let cidr = try! CIDRv4(subnet)
        let configuration = try! NetworkConfiguration(
            name: name, mode: mode, ipv4Subnet: cidr, labels: try! ResourceLabels(labels), plugin: "container-network-vmnet")
        return NetworkResource(configuration: configuration, status: NetworkStatus(ipv4Subnet: cidr, ipv4Gateway: cidr.gateway, ipv6Subnet: nil))
    }

    func list() async throws -> [NetworkResource] {
        state.withLock { $0.networks }
    }

    func create(_ plan: DockerNetworkPlan) async throws -> NetworkResource {
        let network = Self.network(plan.name, subnet: plan.ipv4Subnet?.description ?? "10.9.0.0/24", mode: plan.mode, labels: plan.labels)
        state.withLock { state in
            state.networks.append(network)
            state.calls.append("create \(plan.name) \(plan.mode.rawValue) \(plan.ipv4Subnet?.description ?? "-")")
        }
        return network
    }

    func delete(_ name: String, requiredLabels: [String: String]?) async throws {
        try state.withLock { state in
            guard let network = state.networks.first(where: { $0.id == name }) else { throw DockerAPIError.notFound("network \(name) not found") }
            for (key, value) in requiredLabels ?? [:] where network.labels[key] != value {
                throw DockerAPIError.badRequest("network \(name) does not carry the labels this deletion requires")
            }
            state.networks.removeAll { $0.id == name }
            state.calls.append("delete \(name)")
        }
    }
}

/// The pull fake answers the image routes it does not exercise from an empty store.
extension FakeImages {
    func list() async throws -> [EngineImageRecord] { [] }
    func tag(_ source: String, as target: String) async throws {}
    func delete(_ reference: String) async throws {}
    func collectGarbage() async throws -> UInt64 { 0 }
    func push(reference: String, platform: String?, credential: DockerRegistryCredential?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws
        -> DockerDescriptor?
    { nil }
    func save(references: [String], platform: String?, to file: URL) async throws {}
    func load(from file: URL) async throws -> DockerLoadedImages { DockerLoadedImages(references: []) }
}
