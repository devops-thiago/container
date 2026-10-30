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

import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerPlugin

struct InstanceLogCleanupTests {
    private func loader(_ root: URL, logs: URL?) throws -> PluginLoader {
        try PluginLoader(appRoot: root, installRoot: root, logRoot: logs.map { FilePath($0.path) }, pluginDirectories: [], pluginFactories: [])
    }

    @Test("Instance cleanup never follows a log symlink or removes another instance or a service log")
    func confinedToKnownLogLeaf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("instance-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("configured-logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let loader = try loader(root, logs: logs)
        let target = root.appendingPathComponent("outside-the-log-root")
        try Data("workload data".utf8).write(to: target)
        let leaf = logs.appendingPathComponent("container-runtime-linux-removed.log")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
        let other = logs.appendingPathComponent("container-runtime-linux-kept.log")
        let service = logs.appendingPathComponent("container-core-images.log")
        for path in [other, service] { try Data("keep".utf8).write(to: path) }
        try loader.removeInstanceLog(pluginName: "container-runtime-linux", instanceId: "removed")
        #expect(!FileManager.default.fileExists(atPath: leaf.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "workload data")
        #expect(try String(contentsOf: other, encoding: .utf8) == "keep")
        // An unknown plugin/ID pair must not collide with a core service's filename.
        try loader.removeInstanceLog(pluginName: "container-core", instanceId: "images")
        #expect(try String(contentsOf: service, encoding: .utf8) == "keep")
        try loader.removeInstanceLog(pluginName: "container-runtime-linux", instanceId: "removed")
    }

    @Test("A directory named like a log is never recursively removed")
    func directoryIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("instance-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let leaf = root.appendingPathComponent("container-network-vmnet-net.log")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let child = leaf.appendingPathComponent("workload")
        try Data("keep".utf8).write(to: child)
        let loader = try loader(root, logs: root)
        #expect(throws: (any Error).self) { try loader.removeInstanceLog(pluginName: "container-network-vmnet", instanceId: "net") }
        #expect(try String(contentsOf: child, encoding: .utf8) == "keep")
    }

    @Test("Instance IDs cannot escape the configured log directory", arguments: ["", ".", "..", "../outside", "a/b", "a\u{0}b"])
    func invalidID(_ id: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("instance-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = try loader(root, logs: root)
        #expect(throws: ContainerizationError.self) { try loader.removeInstanceLog(pluginName: "container-runtime-linux", instanceId: id) }
    }

    @Test("No configured logs and a missing log directory need no cleanup")
    func absentLogsAreHarmless() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("instance-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try loader(root, logs: nil).removeInstanceLog(pluginName: "container-runtime-linux", instanceId: "gone")
        try loader(root, logs: root.appendingPathComponent("missing")).removeInstanceLog(pluginName: "container-network-vmnet", instanceId: "gone")
    }
}
