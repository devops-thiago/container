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

import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing
import XPC

@testable import ContainerAPIClient
@testable import ContainerAPIService
@testable import container_apiserver

@Suite(.timeLimit(.minutes(1)))
struct ContainerSysfsAdoptionTests {
    @Test("explicit adoption persists only the permission and preserves the container", arguments: [ManagedSysfsRole.kubernetes, .builder])
    func adoption(role: ManagedSysfsRole) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration(labels: role.requiredLabels)
        let incarnation = try await f.create(service, configuration)
        let path = f.containers.appendingPathComponent(configuration.id)
        let sentinel = path.appendingPathComponent("kept-data")
        try Data("existing node data".utf8).write(to: sentinel)
        let before = try #require(try await service.list().first)
        #expect(!before.configuration.writableSysfs)
        try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: role)
        let snapshot = try #require(try await service.list().first)
        #expect(snapshot.incarnation == incarnation)
        var expected = before.configuration
        expected.writableSysfs = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(snapshot.configuration) == encoder.encode(expected))
        let runtime = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
        #expect(runtime.containerConfiguration?.writableSysfs == true)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "existing node data")
        try await f.start(service, configuration.id)
        let bundle = ContainerResource.Bundle(path: path)
        #expect(try bundle.configuration.writableSysfs)
        let restarted = try f.service()
        #expect(try await restarted.list().first?.configuration.writableSysfs == true)
        // Already adopted: harmless even while this same container is running.
        try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: role)
    }

    @Test("adoption refuses a replacement, an unrelated container, or an active node")
    func refusesUnsafeAdoption() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration(labels: ManagedSysfsRole.kubernetes.requiredLabels)
        let incarnation = try await f.create(service, configuration)
        for expected in ["", UUID().uuidString.lowercased()] {
            await #expect(throws: ContainerizationError.self) {
                try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: expected, role: .kubernetes)
            }
        }
        await #expect(throws: ContainerizationError.self) {
            try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: .builder)
        }
        #expect(try await service.list().first?.configuration.writableSysfs == false)
        try await f.start(service, configuration.id)
        await #expect(throws: ContainerizationError.self) {
            try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: .kubernetes)
        }
        #expect(try await service.list().first?.configuration.writableSysfs == false)
    }

    @Test("an ordinary container cannot be adopted as a managed role", arguments: [ManagedSysfsRole.kubernetes, .builder])
    func ordinaryContainer(role: ManagedSysfsRole) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        let incarnation = try await f.create(service, configuration)
        await #expect(throws: ContainerizationError.self) {
            try await service.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: role)
        }
        #expect(try await service.list().first?.configuration.writableSysfs == false)
    }

    @Test("the native client sends explicit role and incarnation through XPC")
    func route() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration(labels: ManagedSysfsRole.kubernetes.requiredLabels)
        let incarnation = try await f.create(service, configuration)
        let log = Logger(label: "ContainerSysfsAdoptionTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: [XPCRoute.containerAdoptWritableSysfs.rawValue: XPCServer.route(harness.adoptWritableSysfs)], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "sysfs-adoption-test")
        defer { xpc.close() }
        let client = ContainerClient(xpcClient: xpc)
        await #expect(throws: ContainerizationError.self) {
            try await client.adoptWritableSysfs(id: configuration.id, expectedIncarnation: "", role: .kubernetes)
        }
        #expect(try await service.list().first?.configuration.writableSysfs == false)
        try await client.adoptWritableSysfs(id: configuration.id, expectedIncarnation: incarnation, role: .kubernetes)
        #expect(try await service.list().first?.configuration.writableSysfs == true)
    }

    @Test("startup preflights all nodes before adoption and leaves new nodes alone", arguments: [ManagedSysfsRole.kubernetes, .builder])
    func startupPreflight(role: ManagedSysfsRole) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let first = f.configuration(id: "legacy-one", labels: role.requiredLabels)
        let second = f.configuration(id: "legacy-two", labels: role.requiredLabels)
        var fresh = f.configuration(id: "new-node", labels: role.requiredLabels)
        fresh.writableSysfs = true
        for configuration in [first, second, fresh] { try await f.create(service, configuration) }
        let log = Logger(label: "SysfsPreflightTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: [XPCRoute.containerAdoptWritableSysfs.rawValue: XPCServer.route(harness.adoptWritableSysfs)], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "sysfs-preflight-test")
        defer { xpc.close() }
        let client = ContainerClient(xpcClient: xpc)
        let nodes = try await service.list().sorted { $0.id < $1.id }
        let command = "container test start --adopt-legacy"
        await #expect(throws: ContainerizationError.self) {
            try await client.prepareWritableSysfs(nodes, role: role, adoptLegacy: false, adoptionCommand: command)
        }
        var active = nodes
        active[1].status = .running
        await #expect(throws: ContainerizationError.self) {
            try await client.prepareWritableSysfs(active, role: role, adoptLegacy: true, adoptionCommand: command)
        }
        // The first stopped node must not be partially adopted when a later node is active.
        #expect(try await service.list().filter { $0.configuration.writableSysfs }.map(\.id) == [fresh.id])
        let newNode = try #require(nodes.first { $0.id == fresh.id })
        try await client.prepareWritableSysfs([newNode], role: role, adoptLegacy: false, adoptionCommand: command)
        try await client.prepareWritableSysfs(nodes, role: role, adoptLegacy: true, adoptionCommand: command)
        #expect(try await service.list().allSatisfy { $0.configuration.writableSysfs })
    }
}
