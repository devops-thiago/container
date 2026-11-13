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

import Foundation
import Testing

@testable import ContainerCluster

/// Two opens of one file in one process hold separate `flock`s, so a test can be the store
/// and the one asking about it.
@Suite(.processExclusive)
struct HostStoreLivenessTests {
    private func lockPath() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hs-liveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, HostStoreLiveness.lockPath(socketPath: directory.appending(path: "hs.sock").path))
    }

    @Test("the lock is beside the socket")
    func lockIsBesideTheSocket() {
        #expect(HostStoreLiveness.lockPath(socketPath: "/run/hs.sock") == "/run/hs.sock.lock")
        #expect(HostStoreLiveness.lockPath == ClusterHelper.hostStoreSocketPath.string + ".lock")
    }

    @Test("no lock file means no store, and asking does not make one")
    func noFile() throws {
        let (directory, path) = try lockPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(HostStoreLiveness.probe(lockPath: path) == .notRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a store that holds the lock is alive until its descriptor is closed, as the kernel does when it exits")
    func heldThenReleased() throws {
        let (directory, path) = try lockPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = try #require(try HostStoreLiveness.hold(lockPath: path))
        #expect(HostStoreLiveness.probe(lockPath: path) == .alive)
        #expect(HostStoreLiveness.probe(lockPath: path) == .alive, "asking takes nothing from the holder")
        close(held)
        #expect(HostStoreLiveness.probe(lockPath: path) == .notRunning)
    }

    @Test("a second store does not get the lock while the first has it, and gets it once the first lets go")
    func secondStoreWaits() throws {
        let (directory, path) = try lockPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(try HostStoreLiveness.hold(lockPath: path))
        var pauses = 0
        #expect(try HostStoreLiveness.hold(lockPath: path, attempts: 3, pause: { pauses += 1 }) == nil)
        #expect(pauses == 2)
        // The first store exits during the second's wait.
        let second = try HostStoreLiveness.hold(lockPath: path, attempts: 3, pause: { close(first) })
        #expect(second != nil)
        #expect(HostStoreLiveness.probe(lockPath: path) == .alive)
        if let second { close(second) }
    }

    @Test("a lock that cannot be opened says nothing either way")
    func unreadable() throws {
        let (directory, path) = try lockPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A path under a regular file: the open fails, and not because nothing is there.
        FileManager.default.createFile(atPath: path, contents: nil)
        #expect(HostStoreLiveness.probe(lockPath: path + "/nested") == .unknown)
    }
}
