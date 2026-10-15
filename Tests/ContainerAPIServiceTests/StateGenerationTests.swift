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
import ContainerPlugin
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import SystemPackage
import Testing
import XPC

@testable import ContainerAPIClient
@testable import ContainerAPIService
@testable import container_apiserver

/// The API server's state generation (#525) moves on every change a client's listing could
/// show, failed changes included, and the health check reports it. The count is process-wide
/// and these run in parallel with other suites, so each one asserts it moved forward.
struct StateGenerationTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-\(UUID().uuidString)")
        let id = "generation-\(UUID().uuidString.lowercased())"
        let log = Logger(label: "StateGenerationTests")

        func loader(type: String, name: String = "generation-fixture") throws -> PluginLoader {
            let plugins = root.appendingPathComponent("plugins")
            let plugin = plugins.appendingPathComponent(name)
            let bin = plugin.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent(name))
            try Data(
                """
                abstract = "Generation fixture; never executed"
                [servicesConfig]
                loadAtBoot = false
                runAtLoad = false
                defaultArguments = []
                [[servicesConfig.services]]
                type = "\(type)"
                """.utf8
            ).write(to: plugin.appendingPathComponent("config.toml"))
            return try PluginLoader(
                appRoot: root, installRoot: root, logRoot: nil,
                pluginDirectories: [plugins], pluginFactories: [DefaultPluginFactory(logger: log)])
        }

        func containers(type: String = "network", name: String = "generation-fixture") throws -> ContainersService {
            try ContainersService(
                appRoot: root, pluginLoader: loader(type: type, name: name), containerSystemConfig: ContainerSystemConfig(), log: log)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("a generation counts up from where it is")
    func advances() {
        let generation = StateGeneration()
        #expect(generation.current == 0)
        #expect(generation.advance() == 1)
        #expect(generation.advance() == 2)
        #expect(generation.current == 2)
    }

    @Test("the health check reports the generation beside the process nonce")
    func pingReportsIt() async throws {
        let log = Logger(label: "StateGenerationTests")
        var routes: [XPCRoute: XPCServer.RouteHandler] = [:]
        var start = APIServer.Start()
        start.lifecycleGenerationOption = nil  // an unparsed option would trap when read
        start.initializeHealthCheckService(processNonce: "nonce", log: log, routes: &routes)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) }), log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let client = XPCClient(endpoint: xpc_endpoint_create(listener), label: "state-generation-test")
        defer { client.close() }
        let before = StateGeneration.shared.advance()
        let reply = try await client.send(XPCMessage(route: XPCRoute.ping.rawValue), responseTimeout: .seconds(5))
        #expect(reply.uint64IfPresent(key: XPCKeys.stateGeneration.rawValue).map { $0 >= before } == true)
        #expect(reply.string(key: XPCKeys.processNonce.rawValue) == "nonce")
    }

    @Test("volume create and delete count, and so does a delete that fails")
    func volumesCount() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let service = try await VolumesService(
            resourceRoot: FilePath(f.root.appendingPathComponent("volumes").path), containersService: f.containers(), log: f.log)
        var before = StateGeneration.shared.current
        _ = try await service.create(name: "counted", driverOpts: ["size": "64M"])
        #expect(StateGeneration.shared.current > before)
        before = StateGeneration.shared.current
        try await service.delete(name: "counted")
        #expect(StateGeneration.shared.current > before)
        before = StateGeneration.shared.current
        await #expect(throws: (any Error).self) { try await service.delete(name: "never-made") }
        #expect(StateGeneration.shared.current > before)
    }

    @Test("a network's state appearing and going counts")
    func networksCount() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let configuration = try NetworkConfiguration(
            name: "network-\(UUID().uuidString.lowercased())", mode: .nat, plugin: "generation-fixture")
        let service = try await NetworksService(
            pluginLoader: f.loader(type: "network"), resourceRoot: FilePath(f.root.appendingPathComponent("networks").path),
            containersService: f.containers(), defaultNetworkConfiguration: configuration, log: f.log)
        let status = try NetworkStatus(ipv4Subnet: CIDRv4("192.168.129.0/24"), ipv4Gateway: IPv4Address("192.168.129.1"), ipv6Subnet: nil)
        var before = StateGeneration.shared.current
        await service.setServiceState(
            key: configuration.id,
            value: .init(
                configuration: configuration, status: status,
                client: ContainerNetworkClient.NetworkClient(id: configuration.id, plugin: configuration.plugin)))
        #expect(StateGeneration.shared.current > before)
        before = StateGeneration.shared.current
        try await service.delete(id: configuration.id)
        #expect(StateGeneration.shared.current > before)
    }

    @Test("removing a container it keeps counts")
    func containersCount() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let bundle = f.root.appendingPathComponent("containers").appendingPathComponent(f.id)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let configuration = ContainerConfiguration(
            id: f.id,
            image: .init(
                reference: "fixture:latest",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        try ContainerResource.Bundle(path: bundle).set(configuration: configuration)
        // The engine loads a container only when its runtime plugin is there. Loading is not a
        // change: it happens in the initializer, before any client has a count to compare, and
        // a fresh process is told apart by its nonce.
        let service = try f.containers(type: "runtime", name: configuration.runtimeHandler)
        #expect(try await service.list().map(\.id) == [f.id])
        let before = StateGeneration.shared.current
        try await service.delete(id: f.id, force: false)
        #expect(try await service.list().isEmpty)
        #expect(StateGeneration.shared.current > before)
    }
}
