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

struct ParseLimitsTests {
    @Test func aliasesCannotExpandPastTheBudget() throws {
        var yaml = "x-a0: &a0 [leaf]\n"
        for n in 1...16 { yaml += "x-a\(n): &a\(n) [*a\(n - 1), *a\(n - 1)]\n" }
        yaml += "services:\n  web:\n    image: alpine\n"
        #expect(throws: ComposeError.self) { try ComposeNode.parse(yaml: yaml, file: "compose.yaml") }
    }

    @Test func nestingIsBoundedBeforeTheRecursiveParser() throws {
        let yaml = "x-deep: " + String(repeating: "[", count: 256) + "leaf" + String(repeating: "]", count: 256)
        #expect(throws: ComposeError.self) { try ComposeNode.parse(yaml: yaml, file: "deep.yaml") }
    }

    @Test func inputSizeIsBoundedEvenWithoutAliases() throws {
        let yaml = "x-text: " + String(repeating: "a", count: 1_048_577)
        #expect(throws: ComposeError.self) { try ComposeNode.parse(yaml: yaml, file: "large.yaml") }
    }

    @Test func aScalarAliasCannotMultiplyTextPastTheBudget() throws {
        let text = String(repeating: "a", count: 100_000)
        let yaml = "x-text: &text " + text + "\nx-aliases: [" + Array(repeating: "*text", count: 100).joined(separator: ",") + "]"
        #expect(throws: ComposeError.self) { try ComposeNode.parse(yaml: yaml, file: "text.yaml") }
    }

    @Test func aliasedDepthIsBoundedToo() throws {
        var yaml = "x-a0: &a0 [leaf]\n"
        for n in 1...65 { yaml += "x-a\(n): &a\(n) [*a\(n - 1)]\n" }
        #expect(throws: ComposeError.self) { try ComposeNode.parse(yaml: yaml, file: "depth.yaml") }
    }

    @Test func oversizedFilesAreRejectedByTheLoader() throws {
        let project = try TemporaryProject(["compose.yaml": "x-text: " + String(repeating: "a", count: 1_048_577)])
        #expect(loadFailure { try project.load() }.contains { $0.contains("1 MiB") })
    }

    @Test func malformedYamlRetainsItsSourceLocation() throws {
        do {
            _ = try ComposeNode.parse(yaml: "services: [", file: "broken.yaml")
            Issue.record("malformed YAML was accepted")
        } catch let error as ComposeError {
            #expect(error.diagnostics.first?.location?.file == "broken.yaml")
        }
    }

    @Test func nestingWithinTheBudgetStillParses() throws {
        let yaml = "x-deep: " + String(repeating: "[", count: 62) + "leaf" + String(repeating: "]", count: 62)
        _ = try ComposeNode.parse(yaml: yaml, file: "deep.yaml")
    }

    @Test func normalAliasesAndMergePrecedenceStillWork() throws {
        let node = try ComposeNode.parse(
            yaml: """
                x-base: &base {image: alpine, restart: always}
                x-extra: &extra {image: busybox, hostname: test}
                services:
                  web:
                    <<: [*base, *extra]
                    restart: no
                """, file: "compose.yaml")
        #expect(node["services"]?["web"]?["image"]?.scalar == "alpine")
        #expect(node["services"]?["web"]?["restart"]?.scalar == "no")
        #expect(node["services"]?["web"]?["hostname"]?.scalar == "test")
        #expect(node["services"]?["web"]?["image"]?.location.line == 1)
    }

    @Test func aCancelledWorkerStopsReading() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            _ = try ComposeNode.parse(yaml: "services: {}", file: "compose.yaml")
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("the cancelled worker completed its parse")
        } catch is CancellationError {
        }
    }
}

struct InterpolationBudgetTests {
    @Test func variableValuesCannotMultiplyPastTheBudget() throws {
        let value = String(repeating: "a", count: 2 * 1_048_576)
        let interpolator = Interpolator(lookup: { _ in value })
        #expect(throws: Interpolator.Failure.self) { try interpolator.interpolate("$BIG$BIG$BIG$BIG$BIG") }
    }

    @Test func interpolationNestingIsBounded() throws {
        let text = String(repeating: "${UNSET:-", count: 128) + "value" + String(repeating: "}", count: 128)
        #expect(throws: Interpolator.Failure.self) { try Interpolator(lookup: { _ in nil }).interpolate(text) }
    }

    @Test func environmentExpansionHasAnAggregateBudget() throws {
        var text = "V0=a\n"
        for n in 1...23 { text += "V\(n)=${V\(n - 1)}${V\(n - 1)}\n" }
        #expect(throws: ComposeError.self) { try DotEnv.parse(text, file: ".env") }
    }

    @Test func projectInterpolationHasAnAggregateBudget() throws {
        let project = try TemporaryProject(["compose.yaml": "x-first: ${BIG}\nx-second: ${BIG}\nservices:\n  web:\n    image: alpine\n"])
        let failures = loadFailure { try project.load(environment: ["BIG": String(repeating: "a", count: 5 * 1_048_576)]) }
        #expect(failures.contains { $0.contains("8 MiB") })
    }
}
