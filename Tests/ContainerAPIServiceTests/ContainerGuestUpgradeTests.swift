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
import ContainerRuntimeClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import Testing
import XPC

@testable import ContainerAPIClient
@testable import ContainerAPIService

@Suite(.timeLimit(.minutes(1)))
struct ContainerGuestUpgradeTests {
    static func image(_ f: EventServiceFixture) throws -> Filesystem {
        let image = f.root.appendingPathComponent("new-guest.ext4")
        try Data("new guest".utf8).write(to: image)
        let filesystem = Filesystem.block(format: "ext4", source: image.path, destination: "/", options: ["ro"])
        f.guestImage.withLock { $0 = filesystem }
        return filesystem
    }

    @Test("guest upgrade changes only the selected guest disk, survives reload, and works before first boot")
    func upgradePreservesWorkload() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        let incarnation = try await f.create(service, configuration)
        let path = f.containers.appendingPathComponent(configuration.id)
        let bundle = ContainerResource.Bundle(path: path)
        let oldGuest = path.appendingPathComponent("initfs.ext4")
        try Data("custom old guest".utf8).write(to: oldGuest)
        let rootfs = path.appendingPathComponent("rootfs.ext4")
        try Data("workload data".utf8).write(to: rootfs)
        let configPath = try RuntimeConfiguration.readRuntimeConfiguration(from: path).runtimeConfigurationPath
        let before = try Data(contentsOf: configPath)
        _ = try Self.image(f)
        try await service.upgradeGuest(id: configuration.id, expectedIncarnation: incarnation)
        #expect(try Data(contentsOf: URL(fileURLWithPath: bundle.initialFilesystem.source)) == Data("new guest".utf8))
        #expect(try Data(contentsOf: oldGuest) == Data("custom old guest".utf8))
        #expect(try Data(contentsOf: rootfs) == Data("workload data".utf8))
        #expect(try Data(contentsOf: configPath) == before)
        #expect(try await service.list().first?.incarnation == incarnation)
        let reloaded = ContainerResource.Bundle(path: path)
        #expect(reloaded.initialFilesystem.source == bundle.initialFilesystem.source)
        try await f.start(service, configuration.id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: reloaded.initialFilesystem.source)) == Data("new guest".utf8))
    }

    @Test("upgrade rejects stale consent, a running container, and a booted container before its process starts")
    func unsafeUpgradeRefused() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        let incarnation = try await f.create(service, configuration)
        _ = try Self.image(f)
        let bundle = ContainerResource.Bundle(path: f.containers.appendingPathComponent(configuration.id))
        let original = bundle.initialFilesystem.source
        for expected in ["", "different-incarnation"] {
            await #expect(throws: (any Error).self) { try await service.upgradeGuest(id: configuration.id, expectedIncarnation: expected) }
        }
        try await service.bootstrap(id: configuration.id, stdio: [nil, nil, nil], dynamicEnv: [:])
        await #expect(throws: (any Error).self) { try await service.upgradeGuest(id: configuration.id, expectedIncarnation: incarnation) }
        try await service.startProcess(id: configuration.id, processID: configuration.id)
        await #expect(throws: (any Error).self) { try await service.upgradeGuest(id: configuration.id, expectedIncarnation: incarnation) }
        #expect(bundle.initialFilesystem.source == original)
    }

    @Test("a start during the image download is allowed and prevents the subsequent guest replacement")
    func revalidatesAfterDownload() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        let incarnation = try await f.create(service, configuration)
        _ = try Self.image(f)
        f.beforeGuestFetch.withLock { $0 = { try await f.start(service, configuration.id) } }
        await #expect(throws: (any Error).self) { try await service.upgradeGuest(id: configuration.id, expectedIncarnation: incarnation) }
        #expect(try await service.list().first?.status == .running)
        let bundle = ContainerResource.Bundle(path: f.containers.appendingPathComponent(configuration.id))
        #expect(bundle.initialFilesystem.source.hasSuffix("/initfs.ext4"))
    }

    @Test("failed staging preserves the installed guest and cleans temporary files")
    func failedStaging() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let bundle = ContainerResource.Bundle(path: path)
        let source = path.appendingPathComponent("source")
        try Data("first guest".utf8).write(to: source)
        try bundle.installInitialFilesystem(.block(format: "ext4", source: source.path, destination: "/", options: ["ro"]))
        #expect(throws: (any Error).self) {
            try bundle.installInitialFilesystem(.block(format: "ext4", source: path.appendingPathComponent("missing").path, destination: "/", options: ["ro"]))
        }
        #expect(throws: (any Error).self) { try bundle.installInitialFilesystem(.virtiofs(source: path.path, destination: "/", options: [])) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: bundle.initialFilesystem.source)) == Data("first guest".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).filter { $0.hasPrefix(".initfs-upgrade-") }.isEmpty)
    }

    @Test("the guest-upgrade CLI client sends the observed incarnation through the real XPC route")
    func route() async throws {
        let f = EventServiceFixture()
        defer { f.cleanup() }
        let service = try f.service()
        let configuration = f.configuration()
        let incarnation = try await f.create(service, configuration)
        _ = try Self.image(f)
        let log = Logger(label: "GuestUpgradeTests")
        let harness = ContainersHarness(service: service, log: log)
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(connection: listener, routes: [XPCRoute.containerUpgradeGuest.rawValue: XPCServer.route(harness.upgradeGuest)], log: log)
        let listening = Task { try await server.listen() }
        defer {
            xpc_connection_cancel(listener)
            listening.cancel()
        }
        let xpc = XPCClient(endpoint: xpc_endpoint_create(listener), label: "guest-upgrade-test")
        defer { xpc.close() }
        let client = ContainerClient(xpcClient: xpc)
        await #expect(throws: (any Error).self) { try await client.upgradeGuest(id: configuration.id, expectedIncarnation: "") }
        try await client.upgradeGuest(id: configuration.id, expectedIncarnation: incarnation)
        let bundle = ContainerResource.Bundle(path: f.containers.appendingPathComponent(configuration.id))
        #expect(try Data(contentsOf: URL(fileURLWithPath: bundle.initialFilesystem.source)) == Data("new guest".utf8))
    }
}
