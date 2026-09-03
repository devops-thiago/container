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

public enum SystemShutdownClient {
    /// Request safe shutdown over the caller's existing XPC session.
    /// This helper never creates or reacquires an XPC connection.
    public static func shutdown(
        session: XPCClientSession,
        expectedLifecycleGeneration: String,
        expectedProcessNonce: String,
        ownershipToken: String?,
        confirmedTakeover: Bool,
        timeout: Duration? = XPCClient.xpcRegistrationTimeout
    ) async throws {
        let request = XPCMessage(route: .systemShutdown)
        request.set(key: .expectedLifecycleGeneration, value: expectedLifecycleGeneration)
        request.set(key: .expectedProcessNonce, value: expectedProcessNonce)
        if let ownershipToken {
            request.set(key: .ownershipToken, value: ownershipToken)
        }
        request.set(key: .confirmedTakeover, value: confirmedTakeover)

        let response = try await session.send(request, responseTimeout: timeout)
        guard response.bool(key: .acknowledged) else {
            throw ContainerizationError(.invalidState, message: "API server did not acknowledge shutdown")
        }
    }
}
