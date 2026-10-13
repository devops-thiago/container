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
import ContainerNetworkClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerAPIService

struct ResourceOwnershipTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-\(UUID().uuidString)")
        let log = Logger(label: "ResourceOwnershipTests")
        func loader() throws -> PluginLoader {
            let plugins = root.appendingPathComponent("plugins")
            let plugin = plugins.appendingPathComponent("ownership-fixture")
            let bin = plugin.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent("ownership-fixture"))
            try Data(
                """
                abstract = "Ownership fixture; never executed"
                [servicesConfig]
                loadAtBoot = false
                runAtLoad = false
                defaultArguments = []
                [[servicesConfig.services]]
                type = "network"
                """.utf8
            ).write(to: plugin.appendingPathComponent("config.toml"))
            return try PluginLoader(
                appRoot: root, installRoot: root, logRoot: nil,
                pluginDirectories: [plugins], pluginFactories: [DefaultPluginFactory(logger: log)])
        }
        func containers() throws -> ContainersService {
            try ContainersService(appRoot: root, pluginLoader: loader(), containerSystemConfig: ContainerSystemConfig(), log: log)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("volume ownership is checked inside delete, including the XPC route")
    func volumeDeleteRequiresCreationOwner() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let service = try await VolumesService(resourceRoot: FilePath(f.root.appendingPathComponent("volumes").path), containersService: f.containers(), log: f.log)
        let name = "fixture-volume"
        let volume = try await service.create(name: name, driverOpts: ["size": "64M"], labels: ["owner": "other-client"])
        let rejected = await #expect(throws: ContainerizationError.self) {
            try await service.delete(name: name, requiredLabels: ["owner": "this-run"])
        }
        #expect(rejected?.code == .invalidArgument)
        guard rejected != nil else { return }  // A broken guard must fail before an XPC reply fixture is needed.
        let message = XPCMessage(route: .volumeDeleteOwned)
        message.set(key: .volumeName, value: name)
        message.set(key: .requiredLabels, value: try JSONEncoder().encode(["owner": "this-run"]))
        let harness = VolumesHarness(service: service, log: f.log)
        let error = await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(message) }
        #expect(error?.code == .invalidArgument)
        #expect(try await service.inspect(name).labels["owner"] == "other-client")
        #expect(FileManager.default.fileExists(atPath: volume.source))
        let missing = XPCMessage(route: .volumeDeleteOwned)
        missing.set(key: .volumeName, value: name)
        await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(missing) }
        missing.set(key: .requiredLabels, value: try JSONEncoder().encode([String: String]()))
        await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(missing) }
        #expect(try await service.inspect(name).labels["owner"] == "other-client")
        try await service.delete(name: name, requiredLabels: ["owner": "other-client"])
        #expect(try await service.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: volume.source))
    }

    @Test("a replacement volume is not removed by an earlier run's cleanup")
    func replacementVolumeSurvives() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let service = try await VolumesService(resourceRoot: FilePath(f.root.appendingPathComponent("volumes").path), containersService: f.containers(), log: f.log)
        _ = try await service.create(name: "reused", driverOpts: ["size": "64M"], labels: ["owner": "first"])
        try await service.delete(name: "reused")  // Ordinary, unguarded deletion remains supported.
        _ = try await service.create(name: "reused", driverOpts: ["size": "64M"], labels: ["owner": "second"])
        await #expect(throws: ContainerizationError.self) { try await service.delete(name: "reused", requiredLabels: ["owner": "first"]) }
        #expect(try await service.inspect("reused").labels["owner"] == "second")
    }

    @Test("network ownership is checked inside delete, including the XPC route")
    func networkDeleteRequiresCreationOwner() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let configuration = try NetworkConfiguration(
            name: "network-\(UUID().uuidString.lowercased())", mode: .nat,
            labels: ResourceLabels(["owner": "replacement"]), plugin: "ownership-fixture")
        let service = try await NetworksService(
            pluginLoader: f.loader(), resourceRoot: FilePath(f.root.appendingPathComponent("networks").path),
            containersService: f.containers(), defaultNetworkConfiguration: configuration, log: f.log)
        let status = try NetworkStatus(ipv4Subnet: CIDRv4("192.168.128.0/24"), ipv4Gateway: IPv4Address("192.168.128.1"), ipv6Subnet: nil)
        await service.setServiceState(
            key: configuration.id,
            value: .init(
                configuration: configuration, status: status,
                client: ContainerNetworkClient.NetworkClient(id: configuration.id, plugin: configuration.plugin)))
        let rejected = await #expect(throws: ContainerizationError.self) {
            try await service.delete(id: configuration.id, requiredLabels: ["owner": "first"])
        }
        #expect(rejected?.code == .invalidArgument)
        guard rejected != nil else { return }
        let message = XPCMessage(route: .networkDeleteOwned)
        message.set(key: .networkId, value: configuration.id)
        message.set(key: .requiredLabels, value: try JSONEncoder().encode(["owner": "first"]))
        let harness = NetworksHarness(service: service, log: f.log)
        let error = await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(message) }
        #expect(error?.code == .invalidArgument)
        #expect(try await service.list().map(\.id) == [configuration.id])
        let missing = XPCMessage(route: .networkDeleteOwned)
        missing.set(key: .networkId, value: configuration.id)
        await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(missing) }
        missing.set(key: .requiredLabels, value: try JSONEncoder().encode([String: String]()))
        await #expect(throws: ContainerizationError.self) { _ = try await harness.deleteOwned(missing) }
        #expect(try await service.list().map(\.id) == [configuration.id])
        // The fixture has no live helper; successful deletion only clears its cached state.
        try await service.delete(id: configuration.id, requiredLabels: ["owner": "replacement"])
        #expect(try await service.list().isEmpty)
    }

    @Test("malformed ownership data is rejected rather than silently removing the condition")
    func malformedRequirementFailsClosed() throws {
        let message = XPCMessage(route: .volumeDeleteOwned)
        message.set(key: .requiredLabels, value: Data("not-json".utf8))
        #expect(throws: ContainerizationError.self) { try message.requiredLabels() }
    }
}
