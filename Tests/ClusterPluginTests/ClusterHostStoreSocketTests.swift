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
                return true
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
            try ClusterHelper.checkHostStoreSocket(path) { _ in false }
        }
        do {
            try ClusterHelper.checkHostStoreSocket(path) { _ in false }
        } catch {
            #expect("\(error)".contains("not found"))
        }
    }

    @Test func presentSocketThatFitsIsAccepted() throws {
        try ClusterHelper.checkHostStoreSocket(Self.groupContainer + "/run/hs.sock") { _ in true }
    }
}
