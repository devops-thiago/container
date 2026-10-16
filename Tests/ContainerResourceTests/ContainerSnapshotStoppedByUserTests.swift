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

/// How a snapshot carries whether a person ended the container's last run, and how one
/// written before it did reads.
struct ContainerSnapshotStoppedByUserTests {
    @Test("a snapshot without the field, from an older engine or stored JSON, reads as not known")
    func olderSnapshotReadsAsUnknown() throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "old"), status: .stopped, networks: [], exitCode: 143, stoppedByUser: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["stoppedByUser"] as? Bool == true)
        object.removeValue(forKey: "stoppedByUser")
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.stoppedByUser == nil)
        #expect(decoded.exitCode == 143)
    }

    @Test("each answer survives the trip between the engine and its clients", arguments: [true, false])
    func roundTrips(stoppedByUser: Bool) throws {
        let snapshot = ContainerSnapshot(
            configuration: makeTestConfiguration(id: "trip"), status: .stopped, networks: [], exitCode: 137, stoppedByUser: stoppedByUser)
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.stoppedByUser == stoppedByUser)
    }
}
