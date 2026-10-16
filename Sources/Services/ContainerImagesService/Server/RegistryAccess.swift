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

import ContainerAPIClient
import ContainerImagesServiceClient
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import RegistryTransport

/// What a registry login reaches outside the images service: the registry, asked to accept
/// the credential, and the keychain that keeps it. The live one is what the service uses;
/// tests put a held registry and a recording keychain in its place, to drive the service's
/// own sign-in and sign-out steps.
struct RegistryAccess: Sendable {
    /// Ask the registry at `target` to accept `authentication`.
    var check: @Sendable (_ target: (host: String, port: Int?, scheme: String), _ authentication: BasicAuthentication) async throws -> Void
    /// Keep the login for `host`.
    var keep: @Sendable (_ host: String, _ username: String, _ password: String) throws -> Void
    /// Forget the login kept for `host`.
    var forget: @Sendable (_ host: String) throws -> Void
    /// The login the engine keeps for `host`, for a pull or push that brought none of its own:
    /// the environment's, then the keychain's. Nil when there is none.
    var lookup: @Sendable (_ host: String) throws -> (any Authentication)? = { _ in nil }
    /// How long a check may take before it is cancelled and reported as a timeout.
    var deadline: Duration = RegistryLoginLedger.deadline

    static let live = RegistryAccess(
        check: { target, authentication in
            if target.scheme == "http" {
                // Basic auth sent up front to that exact origin, as for an explicit-HTTP pull.
                try await ExplicitHTTPRegistryClient(host: target.host, port: target.port, authentication: authentication).ping()
            } else {
                let client = RegistryClient(
                    host: target.host,
                    scheme: target.scheme,
                    port: target.port,
                    authentication: authentication,
                    retryOptions: .init(
                        maxRetries: 10,
                        retryInterval: 300_000_000,
                        shouldRetry: ({ response in
                            response.status.code >= 500
                        })
                    ),
                    tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration()
                )
                try await client.ping()
            }
        },
        keep: { host, username, password in
            try KeychainHelper(securityDomain: Constants.keychainID).save(hostname: host, username: username, password: password)
        },
        forget: { host in
            try KeychainHelper(securityDomain: Constants.keychainID).delete(hostname: host)
        },
        lookup: { host in
            if let authentication = authenticationFromEnvironment(host: host, ProcessInfo.processInfo.environment) {
                return authentication
            }
            do {
                return try KeychainHelper(securityDomain: Constants.keychainID).lookup(hostname: host)
            } catch let error as KeychainHelper.Error {
                guard case .keyNotFound = error else {
                    throw ContainerizationError(.internalError, message: "error querying keychain for \(host)", cause: error)
                }
                return nil
            }
        })

    /// `CONTAINER_REGISTRY_USER` and `CONTAINER_REGISTRY_TOKEN`, for the host
    /// `CONTAINER_REGISTRY_HOST` names.
    static func authenticationFromEnvironment(host: String, _ environment: [String: String]) -> (any Authentication)? {
        guard environment["CONTAINER_REGISTRY_HOST"] == host else {
            return nil
        }
        guard let user = environment["CONTAINER_REGISTRY_USER"], let password = environment["CONTAINER_REGISTRY_TOKEN"] else {
            return nil
        }
        return BasicAuthentication(username: user, password: password)
    }
}
