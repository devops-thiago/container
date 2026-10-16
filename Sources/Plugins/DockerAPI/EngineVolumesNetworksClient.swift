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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import DockerAPIService
import Foundation

/// The volume routes' engine: the API server's volumes, through the client the
/// `container volume` commands use.
struct EngineVolumesClient: EngineVolumes {
    func list() async throws -> [VolumeConfiguration] {
        try await Self.translated { try await ClientVolume.list() }
    }

    func create(name: String, driverOpts: [String: String], labels: [String: String]) async throws -> VolumeConfiguration {
        try await Self.translated { try await ClientVolume.create(name: name, driver: "local", driverOpts: driverOpts, labels: labels) }
    }

    func delete(_ name: String, requiredLabels: [String: String]?) async throws {
        try await Self.translated { try await ClientVolume.delete(name: name, requiredLabels: requiredLabels) }
    }

    func dataSize(_ name: String) async throws -> UInt64? {
        try await Self.translated { try await ClientVolume.volumeDataSize(name: name) }
    }

    /// The volume service's errors arrive as its own type in process and as words over XPC.
    private static func translated<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await EngineErrors.translated(body)
        } catch let error as VolumeError {
            switch error {
            case .volumeNotFound: throw DockerAPIError.notFound(error.localizedDescription)
            case .volumeAlreadyExists, .volumeInUse: throw DockerAPIError.conflict(error.localizedDescription)
            case .invalidVolumeName, .driverNotSupported, .storageError: throw DockerAPIError.badRequest(error.localizedDescription)
            }
        } catch let error as DockerAPIError {
            throw error
        } catch {
            let text = "\(error)"
            if text.contains("already exists") || text.contains("in use") { throw DockerAPIError.conflict(text) }
            throw error
        }
    }
}

/// The network routes' engine: the API server's networks, through the client the
/// `container network` commands use.
struct EngineNetworksClient: EngineNetworks {
    /// The engine's network plugin, as `container network create` uses by default.
    static let plugin = "container-network-vmnet"

    func list() async throws -> [NetworkResource] {
        try await EngineErrors.translated { try await NetworkClient().list() }
    }

    func create(_ plan: DockerNetworkPlan) async throws -> NetworkResource {
        try await EngineErrors.translated {
            let configuration: NetworkConfiguration
            do {
                configuration = try NetworkConfiguration(
                    name: plan.name, mode: plan.mode, ipv4Subnet: plan.ipv4Subnet, ipv6Subnet: plan.ipv6Subnet, labels: try ResourceLabels(plan.labels),
                    plugin: Self.plugin)
            } catch {
                throw DockerAPIError.badRequest("\(error)")
            }
            do {
                return try await NetworkClient().create(configuration: configuration)
            } catch let error as ContainerizationError where error.isCode(.exists) {
                throw DockerAPIError.conflict("network with name \(plan.name) already exists")
            }
        }
    }

    func delete(_ name: String, requiredLabels: [String: String]?) async throws {
        try await EngineErrors.translated { try await NetworkClient().delete(id: name, requiredLabels: requiredLabels) }
    }
}
