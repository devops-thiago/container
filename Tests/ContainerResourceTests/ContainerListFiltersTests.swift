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

/// The list filters as a value: what the exclusion helpers keep, and what the wire carries.
struct ContainerListFiltersTests {
    @Test("the exclusion helpers keep every other field of the filter")
    func exclusionsKeepTheRest() throws {
        let filters = ContainerListFilters(ids: ["web"], status: .stopped, labels: ["app": "^web$"], name: "^web")
        for excluded in [filters.withoutMachines(), filters.withoutInfrastructure()] {
            #expect(excluded.ids == ["web"])
            #expect(excluded.status == .stopped)
            #expect(excluded.labels["app"] == "^web$")
            #expect(excluded.name == "^web")
            #expect(excluded.labels[ResourceLabelKeys.plugin] != nil)
        }
    }

    @Test("a request without a name filter, as a client that predates it sends, decodes")
    func decodesWithoutName() throws {
        let request = Data(#"{"ids":[],"status":"running","labels":{}}"#.utf8)
        let filters = try JSONDecoder().decode(ContainerListFilters.self, from: request)
        #expect(filters.name == nil)
        #expect(filters.status == .running)
    }

    @Test("a filter without a name does not send one")
    func encodesNoNameKey() throws {
        let encoded = try JSONEncoder().encode(ContainerListFilters(status: .running))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["name"] == nil)
        let named = try JSONEncoder().encode(ContainerListFilters(name: "^web$"))
        #expect(try JSONDecoder().decode(ContainerListFilters.self, from: named).name == "^web$")
    }
}
