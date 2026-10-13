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
import ContainerizationExtras

/// The sign-ins and sign-outs for each registry host, in the order they began.
///
/// A login checks the registry and then keeps the credential. The check can outlast the
/// caller's wait for an answer, and a sign-out or a newer sign-in for the same host can begin
/// meanwhile. A login keeps its credential only while it is still the newest change for its
/// host and its deadline has not passed, so a late answer never writes over what came after.
struct RegistryLoginLedger {
    /// How long a login may take here: less than the 90 seconds `ClientImage.login` waits
    /// for the answer, so the engine gives up first and says why.
    static let deadline: Duration = .seconds(60)

    struct Ticket: Equatable {
        let host: String
        let generation: UInt64
        let started: ContinuousClock.Instant
    }

    private(set) var generations: [String: UInt64] = [:]

    /// A sign-in or sign-out for `host` begins; any earlier one still running is superseded.
    mutating func begin(_ host: String, at now: ContinuousClock.Instant) -> Ticket {
        let generation = (generations[host] ?? 0) + 1
        generations[host] = generation
        return Ticket(host: host, generation: generation, started: now)
    }

    /// Whether the login holding `ticket` may still keep its credential at `now`.
    func mayKeep(_ ticket: Ticket, at now: ContinuousClock.Instant, deadline: Duration = Self.deadline) -> Bool {
        generations[ticket.host] == ticket.generation && now - ticket.started <= deadline
    }

    /// Run the registry check for `server` within `deadline`, cancelling it when the time
    /// runs out, and say so as a timeout.
    static func checking<T: Sendable>(
        _ server: String,
        within deadline: Duration = Self.deadline,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await Timeout.run(for: deadline, operation: operation)
        } catch is CancellationError {
            throw ContainerizationError(
                .timeout,
                message: "the registry \(server) did not answer within \(deadline.components.seconds) seconds")
        }
    }
}
