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

import ContainerNetworkClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIService

struct ResourceLogCleanupTests {
    private func logs(_ fixture: EventServiceFixture) throws -> URL {
        let directory = fixture.root.appendingPathComponent("configured-logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ path: URL, _ value: String = "retained diagnostics") throws {
        try Data(value.utf8).write(to: path)
    }

    @Test("Stopping keeps a container's log; removing it deletes only that instance's log")
    func containerDeletion() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let logRoot = try logs(f)
        let service = try f.service(logRoot: FilePath(logRoot.path))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let instance = logRoot.appendingPathComponent("container-runtime-linux-\(configuration.id).log")
        let peer = logRoot.appendingPathComponent("container-runtime-linux-other.log")
        let daemon = logRoot.appendingPathComponent("container-apiserver.log")
        for path in [instance, peer, daemon] { try write(path) }
        let previousWriter = try FileHandle(forWritingTo: instance)
        defer { try? previousWriter.close() }
        try await service.stop(id: configuration.id, options: .default)
        #expect(FileManager.default.fileExists(atPath: instance.path))
        #expect(try await service.list().contains { $0.id == configuration.id })
        try await service.delete(id: configuration.id, force: false)
        #expect(!FileManager.default.fileExists(atPath: instance.path))
        #expect(try String(contentsOf: peer, encoding: .utf8) == "retained diagnostics")
        #expect(try String(contentsOf: daemon, encoding: .utf8) == "retained diagnostics")
        // Helper logging holds an open file handle. Late output must neither recreate the
        // removed path nor touch the next container's log when an ID is reused.
        try previousWriter.write(contentsOf: Data("late output".utf8))
        #expect(!FileManager.default.fileExists(atPath: instance.path))
        try await f.create(service, f.configuration(id: configuration.id))
        try write(instance, "replacement diagnostics")
        try previousWriter.write(contentsOf: Data("old helper output".utf8))
        #expect(try String(contentsOf: instance, encoding: .utf8) == "replacement diagnostics")
    }

    private func network(_ f: EventServiceFixture, logRoot: URL) async throws -> (NetworksService, NetworkConfiguration, URL) {
        let plugin = "container-network-vmnet"
        let directory = f.root.appendingPathComponent("plugins/\(plugin)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("bin/\(plugin)"))
        try Data(
            """
            abstract = "Deletion fixture; never executed"
            [servicesConfig]
            loadAtBoot = false
            runAtLoad = false
            defaultArguments = []
            [[servicesConfig.services]]
            type = "network"
            """.utf8
        ).write(to: directory.appendingPathComponent("config.toml"))
        let configuration = try NetworkConfiguration(name: "logs-\(UUID().uuidString.lowercased())", mode: .nat, plugin: plugin)
        let root = f.root.appendingPathComponent("networks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try FilesystemEntityStore<NetworkConfiguration>(path: FilePath(root.path), type: "network", log: f.log)
        try await store.create(configuration)
        let service = try await NetworksService(
            pluginLoader: f.loader(logRoot: FilePath(logRoot.path)), resourceRoot: FilePath(root.path),
            containersService: f.service(), defaultNetworkConfiguration: configuration, log: f.log)
        let status = try NetworkStatus(ipv4Subnet: CIDRv4("192.168.129.0/24"), ipv4Gateway: IPv4Address("192.168.129.1"), ipv6Subnet: nil)
        await service.setServiceState(
            key: configuration.id,
            value: .init(configuration: configuration, status: status, client: .init(id: configuration.id, plugin: plugin)))
        return (service, configuration, root.appendingPathComponent(configuration.id))
    }

    @Test("Removing a persisted network deletes its helper log and keeps other network and service logs")
    func networkDeletion() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let logRoot = try logs(f)
        let (service, configuration, entity) = try await network(f, logRoot: logRoot)
        let instance = logRoot.appendingPathComponent("container-network-vmnet-\(configuration.id).log")
        let peer = logRoot.appendingPathComponent("container-network-vmnet-other.log")
        let daemon = logRoot.appendingPathComponent("container-core-images.log")
        for path in [instance, peer, daemon] { try write(path) }
        #expect(FileManager.default.fileExists(atPath: entity.path))
        try await service.delete(id: configuration.id)
        #expect(!FileManager.default.fileExists(atPath: entity.path))
        #expect(!FileManager.default.fileExists(atPath: instance.path))
        #expect(try String(contentsOf: peer, encoding: .utf8) == "retained diagnostics")
        #expect(try String(contentsOf: daemon, encoding: .utf8) == "retained diagnostics")
    }
    @Test("A container whose bundle cannot be removed keeps its diagnostics")
    func failedContainerRemovalKeepsLog() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let logRoot = try logs(f)
        let service = try f.service(logRoot: FilePath(logRoot.path))
        let configuration = f.configuration()
        try await f.create(service, configuration)
        let bundle = f.containers.appendingPathComponent(configuration.id)
        let instance = logRoot.appendingPathComponent("container-runtime-linux-\(configuration.id).log")
        try write(instance)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: bundle.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: bundle.path) }
        _ = try? await service.delete(id: configuration.id, force: false)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(try String(contentsOf: instance, encoding: .utf8) == "retained diagnostics")
    }

    @Test("A network whose persisted configuration cannot be removed keeps its diagnostics")
    func failedNetworkRemovalKeepsLog() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let logRoot = try logs(f)
        let (service, configuration, entity) = try await network(f, logRoot: logRoot)
        let instance = logRoot.appendingPathComponent("container-network-vmnet-\(configuration.id).log")
        try write(instance)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: entity.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: entity.path) }
        _ = try? await service.delete(id: configuration.id)
        #expect(FileManager.default.fileExists(atPath: entity.path))
        #expect(try String(contentsOf: instance, encoding: .utf8) == "retained diagnostics")
    }

}
