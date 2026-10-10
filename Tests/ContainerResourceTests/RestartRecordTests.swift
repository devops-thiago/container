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

@testable import ContainerResource

/// What the restart policy keeps on disk and shows, and how older data reads.
struct RestartRecordTests {
    private func temporaryBundle() throws -> ContainerResource.Bundle {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("restart-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return ContainerResource.Bundle(path: path)
    }

    @Test("a record written to the bundle reads back")
    func roundTrips() throws {
        let bundle = try temporaryBundle()
        defer { try? bundle.delete() }
        let record = RestartRecord(stoppedByUser: true, hasBeenStarted: true, restartCount: 7)
        try bundle.setRestartRecord(record)
        #expect(bundle.restartRecord == record)
    }

    @Test("a bundle from before the record: started if it has an exit, and never stopped by a person")
    func legacyBundles() throws {
        let bundle = try temporaryBundle()
        defer { try? bundle.delete() }
        #expect(bundle.restartRecord == RestartRecord(stoppedByUser: false, hasBeenStarted: false, restartCount: 0))
        try bundle.setExitStatus(ExitRecord(exitCode: 0, exitedAt: Date()))
        #expect(bundle.restartRecord == RestartRecord(stoppedByUser: false, hasBeenStarted: true, restartCount: 0))
    }

    @Test("a record missing fields reads them as their defaults")
    func partialRecord() throws {
        let decoded = try JSONDecoder().decode(RestartRecord.self, from: Data(#"{"hasBeenStarted":true}"#.utf8))
        #expect(decoded == RestartRecord(stoppedByUser: false, hasBeenStarted: true, restartCount: 0))
    }

    @Test("a snapshot from an older engine has no restarts and no restart error")
    func olderSnapshot() throws {
        let snapshot = ContainerSnapshot(configuration: makeTestConfiguration(id: "old"), status: .stopped, networks: [])
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["restartCount"] as? Int == 0)
        object.removeValue(forKey: "restartCount")
        object.removeValue(forKey: "restartError")
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.restartCount == 0)
        #expect(decoded.restartError == nil)
    }

    @Test("a restarting container shows its status, count and last restart error in inspect")
    func inspectShowsRestarts() throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "crashy"), status: .restarting, networks: [],
            restartCount: 4, restartError: "cannot mount /src")
        let managed = ManagedContainer(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(managed)) as? [String: Any])
        let status = try #require(object["status"] as? [String: Any])
        #expect(status["state"] as? String == "restarting")
        #expect(status["restartCount"] as? Int == 4)
        #expect(status["restartError"] as? String == "cannot mount /src")
        let decoded = try JSONDecoder().decode(ManagedContainer.self, from: JSONEncoder().encode(managed))
        #expect(decoded.status.restartCount == 4)
        #expect(decoded.status.state == .restarting)
    }

    @Test("a stop from a client that does not know about engine shutdowns is a person's")
    func stopOptionsDecodeWithoutTheField() throws {
        let decoded = try JSONDecoder().decode(ContainerStopOptions.self, from: Data(#"{"timeoutInSeconds":5,"signal":"SIGTERM"}"#.utf8))
        #expect(decoded.engineShutdown == false)
        #expect(decoded.signal == "SIGTERM")
        let engine = ContainerStopOptions(timeoutInSeconds: 3, signal: nil, engineShutdown: true)
        let roundTripped = try JSONDecoder().decode(ContainerStopOptions.self, from: JSONEncoder().encode(engine))
        #expect(roundTripped.engineShutdown)
        #expect(roundTripped.timeoutInSeconds == 3)
    }
}
