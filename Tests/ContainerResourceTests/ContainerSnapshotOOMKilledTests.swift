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

/// How a snapshot and an exit record carry Docker's `OOMKilled`, and how ones written before
/// they did read.
struct ContainerSnapshotOOMKilledTests {
    @Test("a snapshot without the field, from an older engine or stored JSON, reads as not known")
    func olderSnapshotReadsAsUnknown() throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "old"), status: .stopped, networks: [], exitCode: 137, oomKilled: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["oomKilled"] as? Bool == true)
        object.removeValue(forKey: "oomKilled")
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.oomKilled == nil)
        #expect(decoded.exitCode == 137)
    }

    @Test("each answer survives the trip between the engine and its clients", arguments: [true, false])
    func snapshotRoundTrips(oomKilled: Bool) throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "trip"), status: .stopped, networks: [], exitCode: 137, oomKilled: oomKilled)
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.oomKilled == oomKilled)
    }

    @Test("an exit record from before the field reads as not known; one with it keeps it on disk")
    func exitRecord() throws {
        let old = try JSONDecoder().decode(ExitRecord.self, from: Data(#"{"exitCode":137,"exitedAt":0,"stopRequested":false}"#.utf8))
        #expect(old.exitCode == 137)
        #expect(old.oomKilled == nil)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("exit-record-oom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let bundle = ContainerResource.Bundle(path: path)
        defer { try? bundle.delete() }
        for oomKilled in [true, false] {
            let record = ExitRecord(exitCode: 137, exitedAt: Date(timeIntervalSince1970: 1), stopRequested: false, oomKilled: oomKilled)
            try bundle.setExitStatus(record)
            #expect(bundle.exitStatus == record)
        }
    }
}
