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

@testable import ContainerAPIService

/// The precondition a stop or delete carries when the caller validated a container by ID
/// and must not act on whatever else that ID names by the time the service acts.
struct ContainersServiceLabelPreconditionTests {
    @Test func noRequirementAlwaysPasses() {
        #expect(ContainersService.labelsSatisfied(required: nil, actual: [:]))
        #expect(ContainersService.labelsSatisfied(required: nil, actual: ["a": "b"]))
    }

    @Test func everyRequiredLabelMustMatchExactly() {
        let node = ["com.apple.container.plugin": "k8s", "com.apple.container.resource.role": "control-plane"]
        #expect(ContainersService.labelsSatisfied(required: ["com.apple.container.plugin": "k8s"], actual: node))
        #expect(!ContainersService.labelsSatisfied(required: ["com.apple.container.plugin": "k8s"], actual: [:]))
        #expect(!ContainersService.labelsSatisfied(required: ["com.apple.container.plugin": "k8s"], actual: ["com.apple.container.plugin": "machine"]))
        #expect(
            !ContainersService.labelsSatisfied(
                required: ["com.apple.container.plugin": "k8s", "extra": "yes"], actual: node),
            "a required label the container lacks fails the whole check")
    }

    @Test func anOrdinaryContainerNeverSatisfiesTheNodeRequirement() {
        // The replacement scenario: the ID validated as a node now names a plain container.
        let ordinary = ["app": "web"]
        #expect(!ContainersService.labelsSatisfied(required: ["com.apple.container.plugin": "k8s"], actual: ordinary))
    }

    @Test func incarnationSelectsOneCreationEvenWhenLabelsAndIDMatch() {
        #expect(ContainersService.incarnationSatisfied(expected: nil, actual: "current"))
        #expect(ContainersService.incarnationSatisfied(expected: "current", actual: "current"))
        #expect(!ContainersService.incarnationSatisfied(expected: "old", actual: "replacement"))
        #expect(!ContainersService.incarnationSatisfied(expected: "", actual: "replacement"))
    }

    @Test func generatedIncarnationPersistsOutsideConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-incarnation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generated = try ContainersService.loadOrCreateIncarnation(at: directory)
        #expect(UUID(uuidString: generated) != nil)
        #expect(try ContainersService.loadOrCreateIncarnation(at: directory) == generated)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("incarnation").path))
    }
}
