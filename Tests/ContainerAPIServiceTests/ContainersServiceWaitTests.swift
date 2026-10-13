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
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

/// `wait` on a real ContainersService, loaded from container bundles as the engine loads them
/// at start: the answers a wait gets from what a container recorded and from the exits kept
/// for it, without a runtime to ask.
struct ContainersServiceWaitTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("container-wait-\(UUID().uuidString)")
        let id = "wait-test-\(UUID().uuidString.lowercased())"
        let log = Logger(label: "ContainersServiceWaitTests")

        var containers: URL { root.appendingPathComponent("containers") }
        var bundle: URL { containers.appendingPathComponent(id) }
        var plugins: URL { root.appendingPathComponent("plugins") }
        var configuration: ContainerConfiguration {
            ContainerConfiguration(
                id: id,
                image: .init(
                    reference: "fixture:latest",
                    descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
                process: .init(executable: "/bin/true", arguments: [], environment: []))
        }

        /// A stopped container's bundle, with the exit of its last run when it had one.
        func addStoppedContainer(exit: ExitRecord?) throws {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let resource = ContainerResource.Bundle(path: bundle)
            try resource.set(configuration: configuration)
            if let exit { try resource.setExitStatus(exit) }
        }

        func service() throws -> ContainersService {
            try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
            let plugin = plugins.appendingPathComponent(configuration.runtimeHandler)
            let bin = plugin.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appendingPathComponent(configuration.runtimeHandler))
            try Data(
                """
                abstract = "Wait fixture; never executed"
                [servicesConfig]
                loadAtBoot = false
                runAtLoad = false
                defaultArguments = []
                [[servicesConfig.services]]
                type = "runtime"
                """.utf8
            ).write(to: plugin.appendingPathComponent("config.toml"))
            let loader = try PluginLoader(
                appRoot: root, installRoot: root, logRoot: nil,
                pluginDirectories: [plugins], pluginFactories: [DefaultPluginFactory(logger: log)])
            return try ContainersService(
                appRoot: root, pluginLoader: loader, containerSystemConfig: ContainerSystemConfig(), log: log)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("a stopped container's wait gets the exit it recorded, whenever it comes and after a restart")
    func stoppedContainerAnswersWithItsRecordedExit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let exitedAt = Date(timeIntervalSinceNow: -3600)
        try fixture.addStoppedContainer(exit: ExitRecord(exitCode: 7, exitedAt: exitedAt))
        let service = try fixture.service()

        let status = try await service.wait(id: fixture.id, processID: fixture.id)
        #expect(status.exitCode == 7)
        #expect(status.exitedAt == exitedAt)
    }

    @Test("a stopped container that never ran is asked as before, and has no exit to give")
    func neverRanHasNoExit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.addStoppedContainer(exit: nil)
        let service = try fixture.service()

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.wait(id: fixture.id, processID: fixture.id)
        }
    }

    @Test("an exit kept for another incarnation is not a stopped container's answer")
    func otherIncarnationsExitIsNotTheAnswer() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.addStoppedContainer(exit: ExitRecord(exitCode: 7, exitedAt: Date()))
        let service = try fixture.service()
        await service.recordExit(ExitStatus(exitCode: 3), of: fixture.id, incarnation: "a-removed-predecessor")

        let status = try await service.wait(id: fixture.id, processID: fixture.id)
        #expect(status.exitCode == 7)
    }

    @Test("a container removed after its exit (--rm) answers a late wait with it")
    func removedContainerAnswersWithItsKeptExit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let service = try fixture.service()
        await service.recordExit(ExitStatus(exitCode: 3), of: "gone", incarnation: "one")

        let status = try await service.wait(id: "gone", processID: "gone")
        #expect(status.exitCode == 3)
        await #expect(throws: ContainerizationError.self) {
            _ = try await service.wait(id: "never-was", processID: "never-was")
        }
    }

    @Test("only the init process is answered from a recorded or kept exit")
    func execProcessesAreAskedAsUsual() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.addStoppedContainer(exit: ExitRecord(exitCode: 7, exitedAt: Date()))
        let service = try fixture.service()

        await #expect(throws: ContainerizationError.self) {
            _ = try await service.wait(id: fixture.id, processID: "exec-1")
        }
    }
}
