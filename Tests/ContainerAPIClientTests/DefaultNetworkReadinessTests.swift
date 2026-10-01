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

import ContainerizationError
import Testing

@testable import ContainerAPIClient

struct DefaultNetworkReadinessTests {
    @Test("only the initialized default network authorizes readiness")
    func missingAndReady() async throws {
        await #expect(throws: (any Error).self) { try await DefaultNetworkReadiness.verify(networkIDs: { [] }) }
        await #expect(throws: (any Error).self) { try await DefaultNetworkReadiness.verify(networkIDs: { ["custom"] }) }
        try await DefaultNetworkReadiness.verify(networkIDs: { ["custom", "default"] })
    }

    @Test("network errors and cancelled probes cannot authorize readiness")
    func failedAndCancelled() async {
        enum Failure: Error { case timeout }
        await #expect(throws: Failure.self) { try await DefaultNetworkReadiness.verify(networkIDs: { throw Failure.timeout }) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await DefaultNetworkReadiness.verify(networkIDs: {
                Issue.record("cancelled probe must not issue XPC")
                return ["default"]
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
