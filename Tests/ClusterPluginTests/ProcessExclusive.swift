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

import Testing

/// One test at a time among the suites that carry `.processExclusive`: the ones whose
/// tests depend on something the whole test process shares.
///
/// - Descriptors. A file lock goes when the last descriptor on its open file is closed, and
///   a process being spawned holds a copy of every descriptor of this one until its exec,
///   close-on-exec or not. A test that closes a lock while another test's spawn is in flight
///   can find the lock still held a moment later. So the suites that spawn and the suites
///   that take file locks carry this.
/// - The environment. `KUBECONFIG` names the file a cluster delete edits, and a test that
///   sets it sets it for every test running then. So do the suites that set it or delete.
struct ProcessExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
    private actor Gate {
        private var held = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            guard held else {
                held = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Hand the turn to the next test waiting, if there is one.
        func leave() {
            guard !waiting.isEmpty else {
                held = false
                return
            }
            waiting.removeFirst().resume()
        }
    }

    private static let gate = Gate()

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // A suite's own scope spans all its tests: only a test case takes the turn.
        guard testCase != nil else { return try await function() }
        await Self.gate.enter()
        do {
            try await function()
        } catch {
            await Self.gate.leave()
            throw error
        }
        await Self.gate.leave()
    }
}

extension Trait where Self == ProcessExclusiveTrait {
    /// Run this suite's tests one at a time, and never beside a test of another suite that
    /// carries this.
    static var processExclusive: Self { Self() }
}
