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

@testable import ContainerCompose

struct VersionReportTests {
    private let line = "compose version 1.4.1 (build: release, commit: 2b99b4b)"

    @Test
    func theVersionIsASentenceANumberOrJSON() {
        #expect(ComposeVersionReport.render(line: line, version: "1.4.1", short: false, format: .pretty) == line)
        #expect(ComposeVersionReport.render(line: line, version: "1.4.1", short: true, format: .pretty) == "2.8.0")
        #expect(ComposeVersionReport.render(line: line, version: "1.4.1", short: false, format: .json) == #"{"version":"1.4.1"}"#)
        #expect(ComposeVersionReport.render(line: line, version: "1.4.1", short: true, format: .json) == "2.8.0", "short is the number, whatever the format")
    }

    /// Dev Containers reads `compose version --short` as a Docker Compose release: below 2 it
    /// drops `--profile *`, below 1.21 it strips `-` and `_` from project names, below 2.8 it
    /// names a built image `project_service`, and from 2.17 it sends `additional_contexts`.
    @Test
    func shortIsADockerComposeReleaseInTheWindowThisComposeMatches() throws {
        let short = ComposeVersionReport.render(line: line, version: "1.5.0-172-g45bb8248", short: true, format: .pretty)
        let parts = try short.split(separator: ".").map { try #require(Int($0)) }
        #expect(parts.count == 3)
        #expect(parts.lexicographicallyPrecedes([2, 8, 0]) == false, "image names use a dash")
        #expect(parts.lexicographicallyPrecedes([2, 17, 0]), "additional_contexts are refused here")
    }

    @Test
    func aVersionWithABuildSuffixIsValidJSON() throws {
        let rendered = ComposeVersionReport.render(line: line, version: #"1.4.1-103-g2b99b4b0/"x""#, short: false, format: .json)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(rendered.utf8))
        #expect(decoded == ["version": #"1.4.1-103-g2b99b4b0/"x""#])
    }

    @Test
    func aFormatWrittenAsTheFileOptionIsTheFormat() {
        #expect(ComposeVersionReport.format(named: nil, files: []) == .pretty)
        #expect(ComposeVersionReport.format(named: nil, files: ["json"]) == .json, "version -f json")
        #expect(ComposeVersionReport.format(named: nil, files: ["compose.yaml"]) == .pretty, "a compose file is not a format")
        #expect(ComposeVersionReport.format(named: .pretty, files: ["json"]) == .pretty, "--format is the one asked for")
        #expect(ComposeVersionReport.format(named: nil, files: ["compose.yaml", "json"]) == .json)
    }

    @Test
    func theFormatsAreTheTwoDockerHas() {
        #expect(ComposeVersionReport.Format.allCases.map(\.rawValue) == ["pretty", "json"])
        #expect(ComposeVersionReport.Format(argument: "json") == .json)
        #expect(ComposeVersionReport.Format(argument: "yaml") == nil)
    }
}
