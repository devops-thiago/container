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

/// The one list of engine-managed infrastructure, and the filter built from it.
struct ContainerListFiltersInfrastructureTests {
    private func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    @Test("any plugin-owned container is infrastructure; unrelated user labels are not")
    func classification() {
        #expect(ContainerListFilters.isInfrastructure(labels: [ResourceLabelKeys.plugin: "machine"]))
        #expect(ContainerListFilters.isInfrastructure(labels: [ResourceLabelKeys.plugin: "k8s"]))
        #expect(ContainerListFilters.isInfrastructure(labels: [ResourceLabelKeys.plugin: "future-plugin"]))
        #expect(!ContainerListFilters.isInfrastructure(labels: [:]))
        #expect(!ContainerListFilters.isInfrastructure(labels: ["app": "web"]))
        #expect(!ContainerListFilters.isInfrastructure(labels: [ResourceLabelKeys.plugin: ""]))
    }

    @Test("the filter's pattern, as the service applies it, admits everything but infrastructure")
    func filterPattern() throws {
        let filters = ContainerListFilters(status: .stopped).withoutInfrastructure()
        let pattern = try #require(filters.labels[ResourceLabelKeys.plugin])
        #expect(filters.status == .stopped, "the rest of the filter is kept")
        #expect(!matches(pattern, "machine"))
        #expect(!matches(pattern, "k8s"))
        #expect(matches(pattern, ""), "a container without the label — every ordinary one — passes")
        #expect(!matches(pattern, "k8s-tools"))
        #expect(!matches(pattern, "web"))
    }

    @Test("withoutMachines still excludes only machines, for callers that mean that")
    func machinesOnly() throws {
        let pattern = try #require(ContainerListFilters.all.withoutMachines().labels[ResourceLabelKeys.plugin])
        #expect(!matches(pattern, "machine"))
        #expect(matches(pattern, "k8s"))
    }
}
