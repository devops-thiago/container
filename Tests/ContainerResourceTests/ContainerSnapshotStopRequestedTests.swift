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

/// How a snapshot and an exit record carry whether the last run's end was asked for, and how
/// ones written before they did read.
struct ContainerSnapshotStopRequestedTests {
    @Test("a snapshot without the field, from an older engine or stored JSON, reads as not known")
    func olderSnapshotReadsAsUnknown() throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "old"), status: .stopped, networks: [], exitCode: 143, stopRequested: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["stopRequested"] as? Bool == true)
        object.removeValue(forKey: "stopRequested")
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.stopRequested == nil)
        #expect(decoded.exitCode == 143)
    }

    @Test("each answer survives the trip between the engine and its clients", arguments: [true, false])
    func snapshotRoundTrips(stopRequested: Bool) throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "trip"), status: .stopped, networks: [], exitCode: 137, stopRequested: stopRequested)
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.stopRequested == stopRequested)
    }

    @Test("an exit record from before the field reads as not known; one with it keeps it on disk")
    func exitRecord() throws {
        let old = try JSONDecoder().decode(ExitRecord.self, from: Data(#"{"exitCode":143,"exitedAt":0}"#.utf8))
        #expect(old.exitCode == 143)
        #expect(old.stopRequested == nil)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("exit-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let bundle = ContainerResource.Bundle(path: path)
        defer { try? bundle.delete() }
        for stopRequested in [true, false] {
            let record = ExitRecord(exitCode: 143, exitedAt: Date(timeIntervalSince1970: 1), stopRequested: stopRequested)
            try bundle.setExitStatus(record)
            #expect(bundle.exitStatus == record)
        }
    }
}
