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
    private let hidden = [ResourcePluginValues.machine, ResourcePluginValues.cluster]

    @Test func testWithoutPluginsBuildsExclusionPattern() {
        let filters = ContainerListFilters().withoutPlugins(hidden)
        #expect(filters.labels[ResourceLabelKeys.plugin] == "^(?!(?:machine|cluster)$)")
    }

    @Test func testWithoutPluginsEscapesNames() {
        let filters = ContainerListFilters().withoutPlugins(["a.b"])
        #expect(filters.labels[ResourceLabelKeys.plugin] == #"^(?!(?:a\.b)$)"#)
    }

    @Test func testWithoutPluginsKeepsOtherFilters() {
        let filters = ContainerListFilters(ids: ["a"], status: .stopped).withoutPlugins(hidden)
        #expect(filters.ids == ["a"])
        #expect(filters.status == .stopped)
    }

    @Test func testWithoutPluginsWithNoNamesIsUnchanged() {
        #expect(ContainerListFilters().withoutPlugins([]).labels.isEmpty)
    }

    @Test func testWithPluginBuildsExactMatchPattern() {
        let filters = ContainerListFilters().withPlugin(ResourcePluginValues.cluster)
        #expect(filters.labels[ResourceLabelKeys.plugin] == "^cluster$")
    }

    @Test func testWithPluginEscapesName() {
        let filters = ContainerListFilters().withPlugin("a.b")
        #expect(filters.labels[ResourceLabelKeys.plugin] == #"^a\.b$"#)
    }

    @Test func testWithPluginKeepsOtherFilters() {
        let filters = ContainerListFilters(ids: ["a"], status: .running).withPlugin(ResourcePluginValues.cluster)
        #expect(filters.ids == ["a"])
        #expect(filters.status == .running)
    }

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
        #expect(filters.labelConditions == nil)
        #expect(filters.status == .running)
    }

    @Test("a filter without a name does not send one")
    func encodesNoNameKey() throws {
        let encoded = try JSONEncoder().encode(ContainerListFilters(status: .running))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["name"] == nil)
        #expect(object["labelConditions"] == nil)
        let named = try JSONEncoder().encode(ContainerListFilters(name: "^web$"))
        #expect(try JSONDecoder().decode(ContainerListFilters.self, from: named).name == "^web$")
    }
    @Test("label conditions round-trip without losing presence or repeated predicates")
    func labelConditionsRoundTrip() throws {
        let original = ContainerListFilters(labelConditions: [.init(key: "app"), .init(key: "app", pattern: "^$"), .init(key: "app", pattern: "web")])
        let decoded = try JSONDecoder().decode(ContainerListFilters.self, from: JSONEncoder().encode(original))
        #expect(decoded.labelConditions == original.labelConditions)
    }

}
