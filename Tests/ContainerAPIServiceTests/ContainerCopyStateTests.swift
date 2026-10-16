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
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

/// When a copy into or out of a container can reach its filesystem.
struct ContainerCopyStateTests {
    @Test(
        "a copy reaches a running container and a bootstrapped one whose init has not started",
        arguments: [
            (RuntimeStatus.running, true, true),
            (.stopped, true, true),
            // Controls: a container whose VM is not up has no filesystem to copy into.
            (.stopped, false, false),
            (.unknown, false, false),
            (.stopping, true, false),
            (.restarting, false, false),
        ])
    func copyState(status: RuntimeStatus, bootstrapped: Bool, allowed: Bool) {
        #expect(ContainersService.canCopy(status: status, bootstrapped: bootstrapped) == allowed)
    }

    @Test("the engine says it copies before a start")
    func capability() {
        #expect(APIServerCapability.allCases.contains(.copyBeforeStart))
        #expect(APIServerCapability.decode(APIServerCapability.encode(APIServerCapability.allCases)).contains("copyBeforeStart"))
    }

    @Test("a stopped container that was never bootstrapped still refuses a copy in and out")
    func notBootstrappedIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("container-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "copy-test-\(UUID().uuidString.lowercased())"
        let log = Logger(label: "ContainerCopyStateTests")
        let configuration = ContainerConfiguration(
            id: id,
            image: .init(
                reference: "fixture:latest",
                descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
            process: .init(executable: "/bin/true", arguments: [], environment: []))
        let bundle = root.appendingPathComponent("containers").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ContainerResource.Bundle(path: bundle).set(configuration: configuration)
        try JSONEncoder().encode(ContainerCreateOptions(autoRemove: false)).write(to: bundle.appendingPathComponent("options.json"))
        let plugin = root.appendingPathComponent("plugins").appendingPathComponent(configuration.runtimeHandler)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: plugin.appendingPathComponent("bin").appendingPathComponent(configuration.runtimeHandler))
        try Data(
            """
            abstract = "Copy fixture; never executed"
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
            pluginDirectories: [root.appendingPathComponent("plugins")], pluginFactories: [DefaultPluginFactory(logger: log)])
        let service = try ContainersService(appRoot: root, pluginLoader: loader, containerSystemConfig: ContainerSystemConfig(), log: log)

        await #expect {
            try await service.copyIn(id: id, source: root.path, destination: "/", mode: 0o644)
        } throws: { error in
            (error as? ContainerizationError)?.isCode(.invalidState) == true
        }
        await #expect {
            try await service.copyOut(id: id, source: "/etc/hostname", destination: root.appendingPathComponent("out").path)
        } throws: { error in
            (error as? ContainerizationError)?.isCode(.invalidState) == true
        }
    }
}
