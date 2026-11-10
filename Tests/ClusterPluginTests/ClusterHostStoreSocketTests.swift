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
import Foundation
import ContainerPlugin
import ContainerizationError
import SystemPackage
import Testing

@testable import ContainerCluster

@Suite("host store socket path budget")
struct ClusterHostStoreSocketTests {
    /// An app group container as macOS names it: 82 bytes for a short user name.
    static let groupContainer = "/Users/thiago/Library/Group Containers/TEAMID1234.dev.example.SiliconShipApplicati"
    static let tooLong = groupContainer + "/Library/Application Support/engine/cluster-hoststore.sock"

    @Test func socketIsInTheEngineRunDirectory() {
        let path = ClusterHelper.hostStoreSocketPath
        #expect(path.lastComponent?.string == "hs.sock")
        #expect(path.removingLastComponent() == PathUtils.runDirectoryPath(engineAppRoot: ApplicationRoot.path))
    }

    @Test func socketFollowsTheEngineAppRoot() {
        let root = FilePath("/var/tmp/engine-fixture/app")
        let path = ClusterHelper.hostStoreSocketPath(engineAppRoot: root)
        #expect(path == PathUtils.runDirectoryPath(engineAppRoot: root).appending("hs.sock"))
    }

    @Test func runDirectorySocketFitsAGroupContainer() {
        #expect(Self.groupContainer.utf8.count == 82)
        let path = Self.groupContainer + "/run/" + ClusterHelper.hostStoreSocketName
        #expect(path.utf8.count == 94)
        #expect(ClusterHelper.socketPathFits(path))
    }

    @Test func budgetIsASocketAddress() {
        let fits = "/" + String(repeating: "a", count: 102)
        #expect(ClusterHelper.socketPathFits(fits))
        #expect(!ClusterHelper.socketPathFits(fits + "a"))
    }

    @Test func tooLongPathIsRefusedBeforeLookingForIt() {
        var looked = false
        do {
            try ClusterHelper.checkHostStoreSocket(Self.tooLong) { _ in
                looked = true
                return .listening
            }
            Issue.record("a \(Self.tooLong.utf8.count)-byte path was accepted")
        } catch {
            let message = "\(error)"
            #expect(message.contains("too long for a socket address"))
            #expect(message.contains(Self.tooLong))
            #expect(message.contains("\(Self.tooLong.utf8.count) bytes"))
            #expect(!message.contains("not found"))
        }
        #expect(!looked)
        #expect(Self.tooLong.utf8.count > ClusterHelper.maxSocketPathBytes)
    }

    @Test func missingSocketIsReportedNotFound() {
        let path = Self.groupContainer + "/run/hs.sock"
        #expect(throws: ContainerizationError.self) {
            try ClusterHelper.checkHostStoreSocket(path) { _ in .absent }
        }
        do {
            try ClusterHelper.checkHostStoreSocket(path) { _ in .absent }
        } catch {
            #expect("\(error)".contains("not found"))
        }
    }

    @Test func listeningSocketThatFitsIsAccepted() throws {
        try ClusterHelper.checkHostStoreSocket(Self.groupContainer + "/run/hs.sock") { _ in .listening }
    }

    @Test func socketNothingServesIsRefused() {
        do {
            try ClusterHelper.checkHostStoreSocket(Self.groupContainer + "/run/hs.sock") { _ in .refused }
            Issue.record("a socket nothing serves was accepted")
        } catch {
            #expect("\(error)".contains("nothing is serving"))
        }
    }

    @Test func socketThatCannotBeProbedIsNotRefused() throws {
        try ClusterHelper.checkHostStoreSocket(Self.groupContainer + "/run/hs.sock") { _ in .unknown(errno: EPERM) }
    }

    @Test func probeTellsListeningFromLeftBehindFromAbsent() throws {
        let directory = "/tmp/hs-probe-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/hs.sock"
        #expect(ClusterHelper.probeHostStoreSocket(path) == .absent)

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(server, 1) == 0)
        #expect(ClusterHelper.probeHostStoreSocket(path) == .listening)

        // The server exits and its socket file stays: what an exited cluster-hoststore leaves.
        close(server)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(ClusterHelper.probeHostStoreSocket(path) == .refused)
    }
}
