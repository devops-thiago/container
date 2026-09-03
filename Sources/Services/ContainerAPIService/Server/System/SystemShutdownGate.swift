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

import ContainerXPC
import ContainerizationError

/// Prevents new mutating API requests from entering once safe shutdown begins,
/// and gives already-admitted mutations a bounded opportunity to finish.
public actor SystemShutdownGate {
    private var acceptingMutations = true
    private var activeMutations = 0

    public init() {}

    public nonisolated func wrap(_ handler: @escaping XPCServer.RouteHandler) -> XPCServer.RouteHandler {
        { message, session in
            try await self.enter()
            do {
                let response = try await handler(message, session)
                await self.leave()
                return response
            } catch {
                await self.leave()
                throw error
            }
        }
    }

    /// Stop admitting mutations and wait only until the shared shutdown deadline.
    /// A timed-out mutation will be terminated when the client disconnects and launchd
    /// boots out this API-server generation.
    public func quiesce(until deadline: ContinuousClock.Instant) async -> Bool {
        acceptingMutations = false
        let clock = ContinuousClock()
        while activeMutations > 0 {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                return false
            }
            do {
                try await Task.sleep(for: min(remaining, .milliseconds(100)))
            } catch {
                return false
            }
        }
        return true
    }

    private func enter() throws {
        guard acceptingMutations else {
            throw ContainerizationError(.invalidState, message: "API server shutdown is in progress")
        }
        activeMutations += 1
    }

    private func leave() {
        activeMutations -= 1
    }
}
