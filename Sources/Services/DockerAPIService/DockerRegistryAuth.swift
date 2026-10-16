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
import NIOHTTP1

/// A registry credential a Docker client sent with one request: `X-Registry-Auth` on a pull or
/// push, or the body of `POST /auth`. It is passed to the engine for that request only, never
/// kept and never logged; printing one shows none of it.
public struct DockerRegistryCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var username: String
    /// The password, or the identity token in its place.
    public var secret: String
    /// The registry the client named, as it sent it (`https://index.docker.io/v1/`,
    /// `localhost:5000`); empty when it named none.
    public var serverAddress: String

    public init(username: String, secret: String, serverAddress: String = "") {
        self.username = username
        self.secret = secret
        self.serverAddress = serverAddress
    }

    public var description: String { "DockerRegistryCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What a registry said to a credential: it took it, or refused it with this HTTP status.
public enum DockerLoginCheck: Sendable, Equatable {
    case accepted
    case rejected(status: Int)
}

/// Docker's registry credentials: the `X-Registry-Auth` header and the body of `POST /auth`,
/// both an `AuthConfig`: `username`, `password`, `serveraddress`, `identitytoken` and
/// `registrytoken`.
public enum DockerRegistryAuth {
    public static let header = "X-Registry-Auth"

    /// The credential an `X-Registry-Auth` header carries, or nil for none.
    ///
    /// The header is base64url JSON; standard base64 and missing padding are taken too, as
    /// the Docker CLI's encoding has varied. As dockerd does for a pull and a push, a header that
    /// does not decode is no credential rather than an error. So is one with no username,
    /// password or identity token, which is what the CLI sends for a registry it has no login
    /// for: the engine's own logins are used then.
    ///
    /// A `registrytoken` alone is not used: the engine's registry client has no way to send a
    /// bearer token as it is.
    public static func credential(header value: String?) -> DockerRegistryCredential? {
        guard let value, !value.isEmpty, let data = decodeBase64(value) else { return nil }
        return try? credential(json: data)
    }

    /// The credential the body of `POST /auth` carries. A body that is not an `AuthConfig` is
    /// refused, as dockerd refuses it.
    public static func credential(body: Data) throws(DockerAPIError) -> DockerRegistryCredential {
        guard !body.isEmpty else { throw .badRequest("request body is empty") }
        do {
            return try credential(json: body)
                ?? DockerRegistryCredential(username: "", secret: "", serverAddress: (try? fields(body))?["serveraddress"] ?? "")
        } catch {
            throw .badRequest("invalid JSON body")
        }
    }

    struct NotAnAuthConfig: Error {}

    /// The `AuthConfig` fields, by name in lower case: Go's JSON decoder matches field names
    /// without regard to case. A field that is not a string is not taken.
    static func fields(_ json: Data) throws -> [String: String] {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw NotAnAuthConfig() }
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String { fields[key.lowercased()] = text }
        }
        return fields
    }

    static func credential(json: Data) throws -> DockerRegistryCredential? {
        let fields = try fields(json)
        let username = fields["username"] ?? ""
        let password = fields["password"] ?? ""
        let identityToken = fields["identitytoken"] ?? ""
        let secret = password.isEmpty ? identityToken : password
        guard !username.isEmpty || !secret.isEmpty else { return nil }
        // An identity token stands in for a password; Docker's own convention names its user
        // `<token>` when there is no other.
        let user = username.isEmpty && password.isEmpty ? "<token>" : username
        return DockerRegistryCredential(username: user, secret: secret, serverAddress: fields["serveraddress"] ?? "")
    }

    /// Base64url or standard base64, with or without padding.
    static func decodeBase64(_ text: String) -> Data? {
        var normalized = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized = normalized.replacingOccurrences(of: "=", with: "")
        let remainder = normalized.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    /// The registry a login names: its host, without a scheme or path, and the scheme to reach
    /// it over. As dockerd reads `serveraddress`, the scheme is https unless the address says
    /// http, and an empty address is Docker Hub. Docker Hub's legacy index address
    /// (`https://index.docker.io/v1/`), which the CLI sends for it, is `docker.io`.
    public static func registry(_ serverAddress: String) -> (host: String, scheme: String) {
        var address = serverAddress.trimmingCharacters(in: .whitespaces)
        var scheme = "https"
        for prefix in ["https://", "http://"] where address.lowercased().hasPrefix(prefix) {
            scheme = String(prefix.dropLast(3))
            address = String(address.dropFirst(prefix.count))
        }
        let host = address.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        switch host.lowercased() {
        case "", "index.docker.io", "registry-1.docker.io", "docker.io", "registry.hub.docker.com":
            return ("docker.io", "https")
        default:
            return (host, scheme)
        }
    }
}

/// The engine's registry logins as `POST /auth` sees them. The agent answers it from the
/// images service; tests answer it from a fake.
public protocol EngineRegistryLogin: Sendable {
    /// Asks the registry at `host` (with a port, if any), over `scheme`, whether it takes
    /// `credential`. Keeps nothing. A registry that cannot be asked is an error.
    func checkLogin(host: String, scheme: String, credential: DockerRegistryCredential) async throws -> DockerLoginCheck
}

/// `POST /auth`: `docker login` against this service. The credential is checked with the
/// registry and kept nowhere here: the Docker CLI keeps it itself and sends it with each pull
/// and push as `X-Registry-Auth`.
public enum AuthRoutes {
    public static func register(on router: inout DockerRouter, engine: some EngineRegistryLogin) {
        router.add(.POST, "/auth") { request, _ in try await login(request, engine: engine) }
    }

    struct AuthResponse: Encodable {
        let Status: String
        let IdentityToken: String
    }

    static func login(_ request: DockerRequest, engine: some EngineRegistryLogin) async throws -> DockerResponse {
        let credential = try DockerRegistryAuth.credential(body: Data(request.body.readableBytesView))
        let (host, scheme) = DockerRegistryAuth.registry(credential.serverAddress)
        switch try await engine.checkLogin(host: host, scheme: scheme, credential: credential) {
        case .accepted:
            // No identity token: the engine's registry client does not ask for one.
            return try .json(AuthResponse(Status: "Login Succeeded", IdentityToken: ""))
        case .rejected(let status):
            let endpoint = "\(scheme)://\(host == "docker.io" ? "registry-1.docker.io" : host)/v2/"
            let reason = HTTPResponseStatus(statusCode: status).reasonPhrase
            // dockerd's words; the status is 401 whatever the registry said, as the CLI reads it.
            throw DockerAPIError(.unauthorized, "login attempt to \(endpoint) failed with status: \(status) \(reason)")
        }
    }
}
