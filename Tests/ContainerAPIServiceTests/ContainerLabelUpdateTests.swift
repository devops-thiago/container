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

/// Setting a container's labels after create: only the name label the policy names, kept
/// where the engine reads it back after a restart, unique, and said as a `rename`.
@Suite(.timeLimit(.minutes(1)))
struct ContainerLabelUpdateTests {
    static let nameKey = "dev.siliconship.docker.name"
    static let policy = ContainerLabelPolicy(nameKey: nameKey)

    @Test("a rename sets the name label in memory and on disk, says rename with the old name, and counts as a change")
    func rename() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: Self.policy)
        let configuration = f.configuration(labels: [Self.nameKey: "before", "com.docker.compose.project": "demo"])
        try await f.create(service, configuration)
        try await f.start(service, configuration.id)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        let generation = StateGeneration.shared.current

        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "after"])

        #expect(StateGeneration.shared.current > generation)
        let events = await reader.take(1)
        #expect(EventCollector.actions(events) == ["rename"])
        #expect(events.first?.name == "after")
        #expect(events.first?.attributes["oldName"] == "before")
        #expect(events.first?.labels[Self.nameKey] == "after")
        let listed = try #require(try await service.list().first)
        #expect(listed.configuration.labels == [Self.nameKey: "after", "com.docker.compose.project": "demo"])
        let bundle = ContainerResource.Bundle(path: f.containers.appendingPathComponent(configuration.id))
        #expect(try bundle.configuration.labels[Self.nameKey] == "after")
        let runtime = try RuntimeConfiguration.readRuntimeConfiguration(from: bundle.path)
        #expect(runtime.containerConfiguration?.labels[Self.nameKey] == "after")
        // The same name again changes nothing and says nothing.
        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "after"])
        #expect(await reader.settle().isEmpty)
    }

    @Test("a container renamed before it ever started keeps its name across an engine restart")
    func survivesRestart() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: Self.policy)
        let configuration = f.configuration(labels: [Self.nameKey: "before"])
        try await f.create(service, configuration)
        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "after"])
        // A start makes the bundle's configuration from the runtime configuration: the new
        // name has to be in it.
        try await f.start(service, configuration.id)
        let restarted = try f.service(labelPolicy: Self.policy)
        #expect(try await restarted.list().first?.configuration.labels[Self.nameKey] == "after")
    }

    @Test(
        "only the name label can change; every other key is refused and nothing changes",
        arguments: [
            "dev.siliconship.docker.id", "dev.siliconship.docker.image", "com.apple.container.plugin", "com.docker.compose.project", "anything",
        ])
    func onlyTheNameLabel(key: String) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: Self.policy)
        let configuration = f.configuration(labels: [Self.nameKey: "kept", key: "original"])
        try await f.create(service, configuration)
        let reader = EventCollector(try f.hub.subscribe(since: nil))
        await #expect(throws: ContainerizationError.self) {
            try await service.updateLabels(id: configuration.id, labels: [key: "forged"])
        }
        // Not even alongside an allowed one.
        await #expect(throws: ContainerizationError.self) {
            try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "new", key: "forged"])
        }
        #expect(try await service.list().first?.configuration.labels == [Self.nameKey: "kept", key: "original"])
        #expect(await reader.settle().isEmpty)
        // The control: the name label alone is taken.
        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "new"])
        #expect(try await service.list().first?.configuration.labels[Self.nameKey] == "new")
    }

    @Test("with no name label named, no label can change")
    func fixedPolicy() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration(labels: [Self.nameKey: "kept"])
        try await f.create(service, configuration)
        await #expect(throws: ContainerizationError.self) {
            try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "new"])
        }
    }

    @Test("a name another container holds, as its label or as its ID, is refused", arguments: [true, false])
    func uniqueNames(byLabel: Bool) async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: Self.policy)
        let holder = f.configuration(labels: byLabel ? [Self.nameKey: "taken"] : [:])
        let taken = byLabel ? "taken" : holder.id
        try await f.create(service, holder)
        let configuration = f.configuration(labels: [Self.nameKey: "mine"])
        try await f.create(service, configuration)
        do {
            try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: taken])
            Issue.record("a name in use was given to another container")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.exists))
        }
        // The control: a free name is taken.
        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "free"])
    }

    @Test("a value that is empty, too long or has control characters is refused", arguments: ["", String(repeating: "a", count: 256), "line\nbreak"])
    func values(value: String) throws {
        #expect(throws: ContainerizationError.self) { try Self.policy.validate([Self.nameKey: value]) }
        // The control.
        try Self.policy.validate([Self.nameKey: String(repeating: "a", count: 255)])
    }

    @Test("another incarnation under the same ID is not renamed")
    func incarnation() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: Self.policy)
        let configuration = f.configuration(labels: [Self.nameKey: "kept"])
        let made = try await f.create(service, configuration)
        await #expect(throws: ContainerizationError.self) {
            try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "new"], expectedIncarnation: UUID().uuidString.lowercased())
        }
        try await service.updateLabels(id: configuration.id, labels: [Self.nameKey: "new"], expectedIncarnation: made)
    }

    @Test("through the route, and the server says it has it; the server names the Docker name label and nothing else")
    func route() async throws {
        #expect(APIServer.Start.containerLabelPolicy.mutableKeys == [Self.nameKey])
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service(labelPolicy: APIServer.Start.containerLabelPolicy)
        let configuration = f.configuration(labels: [Self.nameKey: "before"])
        try await f.create(service, configuration)
        let log = Logger(label: "ContainerLabelUpdateTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(
            connection: listener, routes: [XPCRoute.containerUpdateLabels.rawValue: XPCServer.route(harness.updateLabels)], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "label-update-test")
        defer { xpc.close() }
        let client = ContainerClient(xpcClient: xpc)
        try await client.updateLabels(id: configuration.id, labels: [Self.nameKey: "after"])
        #expect(try await service.list().first?.configuration.labels[Self.nameKey] == "after")
        do {
            try await client.updateLabels(id: configuration.id, labels: ["dev.siliconship.docker.id": "x"])
            Issue.record("a label outside the policy was set")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.invalidArgument))
        }
        #expect(APIServerCapability.allCases.contains(.containerLabels))
    }

    @Test("the API server registers the events and label routes, numbers events with its own nonce, and allows the name label")
    func productionWiring() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        var start = APIServer.Start()
        start.lifecycleGenerationOption = nil  // an unparsed option would trap when read
        start.debug = false
        start.appRoot = FilePath(f.root.path)
        var routes: [XPCRoute: XPCServer.RouteHandler] = [:]
        let service = try start.initializeContainersService(
            pluginLoader: try f.loader(), containerSystemConfig: ContainerSystemConfig(), processNonce: "wired-nonce",
            log: Logger(label: "ContainerLabelUpdateTests"), routes: &routes)
        #expect(routes[.containerEvent] != nil)
        #expect(routes[.containerUpdateLabels] != nil)
        #expect(service.events.processNonce == "wired-nonce")
        #expect(service.labelPolicy == APIServer.Start.containerLabelPolicy)
    }
}
