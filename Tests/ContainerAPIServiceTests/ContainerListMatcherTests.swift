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

import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

private func container(_ id: String, status: RuntimeStatus = .running, labels: [String: String] = [:]) -> ContainerSnapshot {
    var configuration = ContainerConfiguration(
        id: id,
        image: .init(
            reference: "fixture:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
        process: .init(executable: "/bin/true", arguments: [], environment: []))
    configuration.labels = labels
    return ContainerSnapshot(configuration: configuration, status: status, networks: [])
}

/// The predicate `ContainersService.list` applies to every container.
struct ContainerListMatcherTests {
    private let fleet = [
        container("web", labels: ["app": "web", "tier": "front"]),
        container("web-2", labels: ["app": "web"]),
        container("db", status: .stopped, labels: ["app": "db"]),
        container("plain"),
    ]

    private func admitted(by filters: ContainerListFilters, of containers: [ContainerSnapshot]) throws -> [String] {
        let matcher = try ContainerListMatcher(filters)
        return containers.filter { matcher.admits($0) }.map(\.id)
    }

    @Test("no filters admit every container")
    func everything() throws {
        #expect(try admitted(by: .all, of: fleet) == ["web", "web-2", "db", "plain"])
    }

    @Test("ids are exact, and any of the listed ones will do")
    func ids() throws {
        #expect(try admitted(by: .init(ids: ["db", "web"]), of: fleet) == ["web", "db"])
        #expect(try admitted(by: .init(ids: ["we"]), of: fleet).isEmpty)
    }

    @Test("a status admits only containers in it")
    func status() throws {
        #expect(try admitted(by: .init(status: .stopped), of: fleet) == ["db"])
        #expect(try admitted(by: .init(status: .stopping), of: fleet).isEmpty)
    }

    @Test("a name is searched for, so a whole name takes anchors")
    func name() throws {
        #expect(try admitted(by: .init(name: "web"), of: fleet) == ["web", "web-2"])
        #expect(try admitted(by: .init(name: "^web$"), of: fleet) == ["web"])
        #expect(try admitted(by: .init(name: "^(web|db)$"), of: fleet) == ["web", "db"])
    }

    @Test("every label must match, and a label a container lacks matches as an empty value")
    func labels() throws {
        #expect(try admitted(by: .init(labels: ["app": "^web$"]), of: fleet) == ["web", "web-2"])
        #expect(try admitted(by: .init(labels: ["app": "^web$", "tier": "^front$"]), of: fleet) == ["web"])
        #expect(try admitted(by: .init(labels: ["tier": "^$"]), of: fleet) == ["web-2", "db", "plain"])
        #expect(try admitted(by: .init(labels: ["app": ContainerListFilters.exclude("web")]), of: fleet) == ["db", "plain"])
    }

    @Test("the filters combine, with the machine exclusion riding along")
    func combined() throws {
        let machine = container("machine-1", labels: [ResourceLabelKeys.plugin: "machine", "app": "web"])
        let filters = ContainerListFilters(status: .running, labels: ["app": "^web$"], name: "-").withoutMachines()
        #expect(try admitted(by: filters, of: fleet + [machine]) == ["web-2"])
    }

    @Test("a pattern that does not compile is refused, naming what it was for")
    func badPattern() {
        let name = #expect(throws: ContainerizationError.self) {
            try ContainerListMatcher(.init(name: "("))
        }
        #expect(name?.code == .invalidArgument)
        #expect(name?.message.contains("for name") == true)

        let label = #expect(throws: ContainerizationError.self) {
            try ContainerListMatcher(.init(labels: ["app": "["]))
        }
        #expect(label?.message.contains("for app") == true)
    }
    @Test("label presence distinguishes an empty value from a missing key")
    func emptyLabelPresence() throws {
        // Exercise the request wire too: pre-fix servers ignore this condition and
        // incorrectly admit the container without the key.
        let request = Data(#"{"ids":[],"labels":{},"labelConditions":[{"key":"app"}]}"#.utf8)
        let filters = try JSONDecoder().decode(ContainerListFilters.self, from: request)
        let values = [container("empty", labels: ["app": ""]), container("valued", labels: ["app": "web"]), container("absent")]
        #expect(try admitted(by: filters, of: values) == ["empty", "valued"])
    }

    @Test("machine exclusion does not replace an explicit plugin predicate")
    func pluginPredicateSurvivesExclusion() throws {
        let key = ResourceLabelKeys.plugin
        let values = [container("pod", labels: [key: "k8s"]), container("vm", labels: [key: "machine"]), container("other", labels: [key: "future"]), container("plain")]
        let filters = ContainerListFilters(labels: [key: "^k8s$"]).withoutMachines()
        #expect(try admitted(by: filters, of: values) == ["pod"])
        #expect(try admitted(by: ContainerListFilters(labels: [key: "^machine$"]).withoutMachines(), of: values).isEmpty)
        #expect(try admitted(by: ContainerListFilters(labels: [key: "^k8s$"]).withoutInfrastructure(), of: values).isEmpty)
    }

    @Test("repeated label conditions are ANDed and explicit empty values require the key")
    func repeatedLabelConditions() throws {
        let values = [container("empty", labels: ["app": ""]), container("web", labels: ["app": "web"]), container("absent")]
        for (patterns, expected) in [
            ("[{\"key\":\"app\"},{\"key\":\"app\",\"pattern\":\"^$\"}]", ["empty"]), ("[{\"key\":\"app\",\"pattern\":\"^web$\"},{\"key\":\"app\",\"pattern\":\"^db$\"}]", []),
        ] {
            let request = Data(("{\"ids\":[],\"labels\":{},\"labelConditions\":" + patterns + "}").utf8)
            let filters = try JSONDecoder().decode(ContainerListFilters.self, from: request)
            #expect(try admitted(by: filters, of: values) == expected)
        }
    }

    @Test("invalid additional label patterns are refused before scanning")
    func badAdditionalPattern() {
        let error = #expect(throws: ContainerizationError.self) {
            try ContainerListMatcher(.init(labelConditions: [.init(key: "app", pattern: "[")]))
        }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message.contains("for app") == true)
    }

}
