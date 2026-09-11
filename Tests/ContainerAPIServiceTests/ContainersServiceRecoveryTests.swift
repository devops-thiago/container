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
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct ContainersServiceRecoveryTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.withLock { entries.append(entry) }
        }

        var values: [String] { lock.withLock { entries } }
    }

    private struct CapturingLogHandler: LogHandler {
        var logLevel: Logger.Level = .trace
        var metadata: Logger.Metadata = [:]
        let capture: Capture

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            capture.append("\(event.message) \(event.metadata ?? [:])")
        }
    }

    private struct Fixture {
        let root: URL
        let id = "recovery-test-\(UUID().uuidString.lowercased())"
        let capture = Capture()

        var containers: URL { root.appendingPathComponent("containers") }
        var bundle: URL { containers.appendingPathComponent(id) }
        var plugins: URL { root.appendingPathComponent("plugins") }
        var log: Logger {
            Logger(label: "ContainersServiceRecoveryTests", factory: { _ in CapturingLogHandler(capture: capture) })
        }
        var configuration: ContainerConfiguration {
            ContainerConfiguration(
                id: id,
                image: .init(
                    reference: "fixture:latest",
                    descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
                process: .init(executable: "/bin/true", arguments: [], environment: []))
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("container-recovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
            try restoreConfiguration()
            // Include recovery material and an inert authorization blob: failed loading
            // must neither activate grants nor destroy the data needed by a later recovery.
            for filename in ["rootfs.ext4", "stdio.log", "vminitd.log", "kernel.bin", "host-directory-bookmarks.json"] {
                try Data("sentinel:\(filename):\(UUID())".utf8).write(to: bundle.appendingPathComponent(filename))
            }
        }

        func restoreConfiguration() throws {
            try ContainerResource.Bundle(path: bundle).set(configuration: configuration)
        }

        func installPlugin() throws {
            let plugin = plugins.appendingPathComponent(configuration.runtimeHandler)
            let bin = plugin.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent(configuration.runtimeHandler))
            try Data(
                """
                abstract = "Recovery fixture; never executed"
                [servicesConfig]
                loadAtBoot = false
                runAtLoad = false
                defaultArguments = []
                [[servicesConfig.services]]
                type = "runtime"
                """.utf8
            ).write(to: plugin.appendingPathComponent("config.toml"))
        }

        func loader() throws -> PluginLoader {
            try PluginLoader(
                appRoot: root, installRoot: root, logRoot: nil,
                pluginDirectories: [plugins], pluginFactories: [DefaultPluginFactory(logger: log)])
        }

        func load() throws -> [String: ContainersService.ContainerState] {
            try ContainersService.loadAtBoot(root: containers, loader: loader(), log: log)
        }

        func contents() throws -> [String: Data] {
            let files = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
            return try Dictionary(
                uniqueKeysWithValues: files.compactMap { file in
                    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                    return (file.lastPathComponent, try Data(contentsOf: file))
                })
        }

        func writeRuntimeConfiguration(container: ContainerConfiguration?) throws {
            try RuntimeConfiguration(
                path: bundle,
                initialFilesystem: .virtiofs(source: "/fixture/init", destination: "/", options: ["ro"]),
                kernel: .init(path: bundle.appendingPathComponent("kernel.bin"), platform: .linuxArm),
                containerConfiguration: container
            ).writeRuntimeConfiguration()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("Missing runtime preserves all bundle bytes and never publishes a stopped row", arguments: [false, true])
    func missingPluginPreservesBundle(existingIncarnation: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        if existingIncarnation {
            try Data(UUID().uuidString.lowercased().utf8).write(to: fixture.bundle.appendingPathComponent("incarnation"))
        }
        let before = try fixture.contents()

        let failed = try fixture.load()

        #expect(failed[fixture.id] == nil)
        #expect(try fixture.contents() == before)
        #expect(fixture.capture.values.contains { $0.contains("preserved") && $0.contains(fixture.bundle.path) && $0.contains(fixture.configuration.runtimeHandler) })

        try fixture.installPlugin()
        let restored = try #require(fixture.load()[fixture.id])
        #expect(restored.snapshot.configuration.id == fixture.id)
        #expect(restored.snapshot.status == .stopped)
        #expect(restored.client == nil)
        #expect(UUID(uuidString: restored.snapshot.incarnation) != nil)
        for (name, bytes) in before {
            #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent(name)) == bytes)
        }
    }

    @Test("Invalid or unreadable configuration and failed fallback preserve recovery material", arguments: ["invalid", "unreadable", "missing", "runtime-missing-container"])
    func configurationFailurePreservesBundle(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installPlugin()
        let config = fixture.bundle.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: config)
        switch kind {
        case "unreadable":
            // A directory cannot be read as configuration data regardless of UID or ACLs.
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        case "missing":
            break
        default:
            try Data("invalid-json".utf8).write(to: config)
        }
        if kind == "runtime-missing-container" {
            try fixture.writeRuntimeConfiguration(container: nil)
        } else {
            try Data("also-invalid-json".utf8).write(to: fixture.bundle.appendingPathComponent("runtime-configuration.json"))
        }
        let before = try fixture.contents()

        #expect(try fixture.load().isEmpty)
        #expect(try fixture.contents() == before)
        #expect(
            fixture.capture.values.contains {
                $0.contains("preserved") && $0.contains(fixture.bundle.path)
                    && $0.contains("config.json") && $0.contains("runtime-configuration.json")
            })

        if kind == "unreadable" { try FileManager.default.removeItem(at: config) }
        try fixture.restoreConfiguration()
        #expect(try fixture.load()[fixture.id]?.snapshot.configuration.id == fixture.id)
        #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4")) == before["rootfs.ext4"])
    }

    @Test("A valid runtime configuration still recovers a never-started container")
    func runtimeConfigurationFallbackRemainsSupported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installPlugin()
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("config.json"))
        try fixture.writeRuntimeConfiguration(container: fixture.configuration)
        let before = try fixture.contents()

        #expect(try fixture.load()[fixture.id]?.snapshot.configuration.id == fixture.id)
        #expect(try Data(contentsOf: fixture.bundle.appendingPathComponent("rootfs.ext4")) == before["rootfs.ext4"])
    }

    @Test("An incarnation migration failure still fails closed without deleting data")
    func incarnationFailurePreservesBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installPlugin()
        try FileManager.default.createDirectory(at: fixture.bundle.appendingPathComponent("incarnation"), withIntermediateDirectories: false)
        let before = try fixture.contents()

        #expect(throws: (any Error).self) { _ = try fixture.load() }
        #expect(try fixture.contents() == before)
    }

    @Test("Creating a container cannot reuse an ID with preserved recovery data")
    func createRejectsPreservedBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try fixture.contents()
        let service = try ContainersService(
            appRoot: fixture.root, pluginLoader: fixture.loader(),
            containerSystemConfig: ContainerSystemConfig(), log: fixture.log)

        #expect(try await service.list().isEmpty)
        let error = await #expect(throws: ContainerizationError.self) {
            try await service.create(
                configuration: fixture.configuration,
                kernel: .init(path: fixture.bundle.appendingPathComponent("kernel.bin"), platform: .linuxArm),
                options: .default)
        }

        #expect(error?.code == .exists)
        #expect(try fixture.contents() == before)
    }

    @Test("A bundle restored during create preparation is never entered or removed")
    func exclusiveCreationPreservesRestoredBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let path = fixture.containers.appendingPathComponent("restored")
        #expect(!FileManager.default.fileExists(atPath: path.path))
        // Deterministically stand in for a restore while asynchronous preparation
        // is suspended, after create's initial check but before its transaction.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let sentinel = path.appendingPathComponent("rootfs.ext4")
        let bytes = Data("restored-user-data".utf8)
        try bytes.write(to: sentinel)

        await #expect(throws: (any Error).self) {
            try await ContainersService.withNewContainerDirectory(at: path) {
                Issue.record("create entered an existing recovery bundle")
            }
        }

        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test("Creation rollback removes only the newly reserved directory")
    func exclusiveCreationOwnsItsRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let path = fixture.containers.appendingPathComponent("new")
        let before = try fixture.contents()

        await #expect(throws: ContainerizationError.self) {
            try await ContainersService.withNewContainerDirectory(at: path) {
                try Data("partial configuration".utf8).write(to: path.appendingPathComponent("runtime-configuration.json"))
                throw ContainerizationError(.internalError, message: "fixture create failure")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try fixture.contents() == before)
        let result = try await ContainersService.withNewContainerDirectory(at: path) { "created" }
        #expect(result == "created")
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("One unreadable bundle does not prevent a healthy container from loading")
    func healthyContainerStillLoads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installPlugin()
        let healthy = fixture.containers.appendingPathComponent("healthy")
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: false)
        var configuration = fixture.configuration
        configuration.id = "healthy"
        try ContainerResource.Bundle(path: healthy).set(configuration: configuration)
        try Data("invalid-json".utf8).write(to: fixture.bundle.appendingPathComponent("config.json"))
        let before = try fixture.contents()

        let loaded = try fixture.load()

        #expect(Set(loaded.keys) == ["healthy"])
        #expect(loaded["healthy"]?.snapshot.configuration.id == "healthy")
        #expect(try fixture.contents() == before)
    }

    @Test("Explicit auto-remove containers still delete their persisted authorization and bundle")
    func autoRemoveStillReapsBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try ContainerResource.Bundle(path: fixture.bundle).write(filename: "options.json", value: ContainerCreateOptions(autoRemove: true))

        #expect(try fixture.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.path))
        #expect(fixture.capture.values.contains { $0.contains("reap auto-remove container") && $0.contains(fixture.id) })
    }

    @Test("Auto-remove fails closed if persisted authorization cannot be removed")
    func autoRemoveAuthorizationFailurePreservesBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try ContainerResource.Bundle(path: fixture.bundle).write(filename: "options.json", value: ContainerCreateOptions(autoRemove: true))
        let before = try fixture.contents()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.bundle.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.bundle.path) }

        let error = #expect(throws: ContainerizationError.self) { _ = try fixture.load() }

        #expect(error?.code == .internalError)
        #expect(try fixture.contents() == before)
    }
}
