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
import Foundation
import Testing

struct SystemHealthCodingTests {
    private func health(_ extra: [String: Any] = [:], dropping: String? = nil) throws -> SystemHealth {
        var object: [String: Any] = [
            "appRoot": "file:///tmp/app/", "installRoot": "file:///tmp/install/", "apiServerVersion": "1",
            "apiServerCommit": "c", "apiServerBuild": "release", "apiServerAppName": "container",
        ]
        object.merge(extra) { _, new in new }
        if let dropping { object.removeValue(forKey: dropping) }
        return try JSONDecoder().decode(SystemHealth.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("a health snapshot from before capabilities decodes with none")
    func withoutCapabilities() throws {
        let decoded = try health()
        #expect(decoded.capabilities.isEmpty)
        #expect(!decoded.supports(.containerEvents))
        #expect(decoded.processNonce == nil)
    }

    @Test("capabilities that are there are kept")
    func withCapabilities() throws {
        let decoded = try health(["capabilities": ["containerEvents"], "processNonce": "n"])
        #expect(decoded.supports(.containerEvents))
        #expect(!decoded.supports(.containerLabels))
        #expect(decoded.processNonce == "n")
    }

    @Test("a required field is still required")
    func requiredFieldMissing() {
        #expect(throws: DecodingError.self) { try health(dropping: "apiServerAppName") }
    }

    @Test("an encoded snapshot decodes to the same values")
    func roundTrip() throws {
        let original = SystemHealth(
            appRoot: URL(fileURLWithPath: "/tmp/a"), installRoot: URL(fileURLWithPath: "/tmp/i"), logRoot: "/tmp/l", apiServerVersion: "1",
            apiServerCommit: "c", apiServerBuild: "debug", apiServerAppName: "x", lifecycleProtocolVersion: 1, lifecycleGeneration: "g",
            processNonce: "n", stateGeneration: 7, capabilities: ["containerEvents", "containerLabels"])
        let decoded = try JSONDecoder().decode(SystemHealth.self, from: JSONEncoder().encode(original))
        #expect(decoded.appRoot == original.appRoot)
        #expect(decoded.logRoot == original.logRoot)
        #expect(decoded.stateGeneration == 7)
        #expect(decoded.lifecycleGeneration == "g")
        #expect(decoded.capabilities == original.capabilities)
    }
}
