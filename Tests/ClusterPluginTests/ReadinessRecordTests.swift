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

import Darwin
import Foundation
import Testing

@testable import ContainerCluster

/// Executes the production record scripts against a private directory, never the
/// real guest or host record location. Used by both record and lifecycle tests.
final class ReadinessFileFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-policy-\(UUID())")
    var file: URL { root.appendingPathComponent("state/readiness") }

    init() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    enum Failure: Error {
        case timedOut
        case write(Int32)
    }

    func run(_ script: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "readiness-test", file.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw Failure.timedOut
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func store(_ policy: ClusterReadinessPolicy, name: String = "dev") throws {
        let code = try run(ClusterReadinessRecord.writeScript, arguments: [name, policy.rawValue])
        guard code == 0 else { throw Failure.write(code) }
    }
    func read(name: String = "dev") throws -> ClusterReadinessPolicy? {
        try ClusterReadinessRecord.policy(exitCode: run(ClusterReadinessRecord.readScript, arguments: [name]), name: name)
    }
}

struct ReadinessRecordTests {
    @Test func missingRecordDoesNotClaimNoCNI() throws {
        let f = try ReadinessFileFixture()
        #expect(try f.read() == nil)
    }

    @Test func recordsBothPoliciesAndPreservesOtherData() throws {
        let f = try ReadinessFileFixture()
        let data = f.file.deletingLastPathComponent().appendingPathComponent("workload-data")
        try Data("keep".utf8).write(to: data)
        try f.store(.registered)
        #expect(try f.read() == .registered)
        try f.store(.ready)
        #expect(try f.read() == .ready)
        #expect(try String(contentsOf: data, encoding: .utf8) == "keep")
        let mode = try FileManager.default.attributesOfItem(atPath: f.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.file.deletingLastPathComponent().path).sorted() == ["readiness", "workload-data"])
    }

    @Test(arguments: [
        "NotReady\n", "container-cluster-readiness-v2\ndev\nregistered\n",
        "container-cluster-readiness-v1\ndev\nregistered\n\0",
        "container-cluster-readiness-v1\nother\nregistered\n",
        "container-cluster-readiness-v1\ndev\nunknown\n",
        "container-cluster-readiness-v1\ndev\nregistered\n" + String(repeating: "\n", count: 5000),
    ])
    func malformedRecordFailsRatherThanWeakeningReadiness(contents: String) throws {
        let f = try ReadinessFileFixture()
        try Data(contents.utf8).write(to: f.file)
        #expect(throws: (any Error).self) { try f.read() }
        #expect(try String(contentsOf: f.file, encoding: .utf8) == contents)
    }

    @Test func directoryAtRecordPathIsNotSilentlyAcceptedByRename() throws {
        let f = try ReadinessFileFixture()
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try f.store(.registered) }
        #expect(throws: (any Error).self) { try f.read() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.file.path).isEmpty)
    }

    @Test func nameIsDataRatherThanAShellCommand() throws {
        let f = try ReadinessFileFixture()
        let marker = f.root.appendingPathComponent("unexpected-command")
        let name = "dev; touch '\(marker.path)'"
        try f.store(.registered, name: name)
        #expect(try f.read(name: name) == .registered)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func readErrorsAreNotTreatedAsMissingMetadata() throws {
        let f = try ReadinessFileFixture()
        try f.store(.ready)
        let code = try f.run("cmp() { return 2; }\n" + ClusterReadinessRecord.readScript, arguments: ["dev"])
        #expect(code == 70)
        #expect(throws: (any Error).self) { try ClusterReadinessRecord.policy(exitCode: code, name: "dev") }
    }
}
