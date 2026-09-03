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

// Copyright © 2026 Apple Inc. and the container project authors.
// SPDX-License-Identifier: Apache-2.0

import AsyncHTTPClient
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import NIOCore
import NIOHTTP1

/// OCI transport for the one case `RegistryClient` intentionally refuses: a credential over
/// explicitly selected plaintext HTTP. Callers must opt into this type after selecting `http`;
/// it never probes HTTPS and never falls back from HTTPS. Credentials are sent preemptively to
/// the selected registry origin, and redirects are rejected so they cannot move to another host.
public final class ExplicitHTTPRegistryClient: ContentClient, @unchecked Sendable {
    enum TransportPolicyError: Error, CustomStringConvertible, Equatable, Sendable {
        case credentialBearingRedirect(statusCode: Int)

        var statusCode: Int {
            switch self {
            case .credentialBearingRedirect(let statusCode):
                statusCode
            }
        }

        var description: String {
            "insecure HTTP registry redirected a credential-bearing request; transfer stopped (HTTP status \(statusCode))"
        }
    }

    private let client: HTTPClient
    private let base: URLComponents
    private let authentication: any Authentication
    private let bufferSize: Int

    public convenience init(
        reference: String,
        authentication: any Authentication,
        bufferSize: Int = 4 * 1_048_576
    ) throws {
        let ref = try Reference.parse(reference)
        guard let domain = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "invalid domain for image reference \(reference)")
        }
        guard let url = URL(string: "http://\(domain)"), let host = url.host else {
            throw ContainerizationError(.invalidArgument, message: "invalid HTTP registry \(domain)")
        }
        self.init(host: host, port: url.port, authentication: authentication, bufferSize: bufferSize)
    }

    public init(
        host: String,
        port: Int?,
        authentication: any Authentication,
        bufferSize: Int = 4 * 1_048_576
    ) {
        var base = URLComponents()
        base.scheme = "http"
        base.host = host
        base.port = port
        self.base = base
        self.authentication = authentication
        self.bufferSize = bufferSize

        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        self.client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }

    deinit { _ = client.shutdown() }

    /// Internal so deterministic tests can prove the credential is attached only to the exact
    /// explicitly selected HTTP origin without opening a socket or touching Keychain.
    func makeRequest(
        path: String,
        method: HTTPMethod = .GET,
        headers: [(String, String)] = []
    ) async throws -> HTTPClientRequest {
        var components = base
        components.path = path
        guard let url = components.url?.absoluteString else {
            throw ContainerizationError(.invalidArgument, message: "invalid registry path \(path)")
        }
        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers.add(name: "Authorization", value: try await authentication.token())
        for (name, value) in headers {
            request.headers.add(name: name, value: value)
        }
        return request
    }

    private func execute(
        path: String,
        method: HTTPMethod = .GET,
        headers: [(String, String)] = []
    ) async throws -> HTTPClientResponse {
        let request = try await makeRequest(path: path, method: method, headers: headers)
        let response = try await client.execute(request, deadline: .distantFuture)
        try Self.rejectRedirect(statusCode: Int(response.status.code))
        return response
    }

    static func rejectRedirect(statusCode: Int) throws {
        guard !(300..<400).contains(statusCode) else {
            throw TransportPolicyError.credentialBearingRedirect(statusCode: statusCode)
        }
    }

    private func requireOK(_ response: HTTPClientResponse, path: String) throws {
        guard response.status == .ok else {
            throw RegistryClient.Error.invalidStatus(
                url: base.string.map { $0 + path } ?? path,
                response.status,
                reason: nil)
        }
    }

    public func ping() async throws {
        let path = "/v2/"
        let response = try await execute(path: path)
        try requireOK(response, path: path)
    }

    public func resolve(name: String, tag: String) async throws -> Descriptor {
        let path = "/v2/\(name)/manifests/\(tag)"
        let mediaTypes = [
            MediaTypes.dockerManifest,
            MediaTypes.dockerManifestList,
            MediaTypes.imageManifest,
            MediaTypes.index,
            "*/*",
        ]
        let response = try await execute(
            path: path,
            method: .HEAD,
            headers: [("Accept", mediaTypes.joined(separator: ", "))])
        try requireOK(response, path: path)
        guard let digestHeader = response.headers.first(name: "Docker-Content-Digest") else {
            throw ContainerizationError(.invalidArgument, message: "missing required header Docker-Content-Digest")
        }
        let digest = try ParsedDigest(parsing: digestHeader).description
        guard let mediaType = response.headers.first(name: "Content-Type") else {
            throw ContainerizationError(.invalidArgument, message: "missing required header Content-Type")
        }
        guard
            let length = response.headers.first(name: "Content-Length"),
            let size = Int64(length), size >= 0
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid or missing Content-Length")
        }
        return Descriptor(mediaType: mediaType, digest: digest, size: size)
    }

    public func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        let data = try await fetchData(name: name, descriptor: descriptor)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        let path = resourcePath(name: name, descriptor: descriptor)
        let response = try await execute(path: path, headers: [("Accept", descriptor.mediaType)])
        try requireOK(response, path: path)
        let limit = max(bufferSize, Int(clamping: descriptor.size))
        let body = try await response.body.collect(upTo: limit)
        return Data(body.readableBytesView)
    }

    public func fetchBlob(
        name: String,
        descriptor: Descriptor,
        into file: URL,
        progress: ProgressHandler?
    ) async throws -> (Int64, SHA256Digest) {
        let path = resourcePath(name: name, descriptor: descriptor, forceBlob: true)
        let response = try await execute(path: path, headers: [("Accept", descriptor.mediaType)])
        try requireOK(response, path: path)
        let handle = try FileHandle(forWritingTo: Self.createOrReplace(file))
        defer { try? handle.close() }
        var hasher = SHA256()
        var received: Int64 = 0
        for try await buffer in response.body {
            let data = Data(buffer.readableBytesView)
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            received += Int64(data.count)
            await progress?([.addSize(Int64(data.count))])
        }
        try handle.synchronize()
        return (received, hasher.finalize())
    }

    public func push<T: Sendable & AsyncSequence>(
        name: String,
        ref: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        throw ContainerizationError(.unsupported, message: "explicit HTTP registry push is not supported")
    }

    private func resourcePath(name: String, descriptor: Descriptor, forceBlob: Bool = false) -> String {
        let manifestTypes = [
            MediaTypes.dockerManifest,
            MediaTypes.dockerManifestList,
            MediaTypes.imageManifest,
            MediaTypes.index,
        ]
        let resource = !forceBlob && manifestTypes.contains(descriptor.mediaType) ? "manifests" : "blobs"
        return "/v2/\(name)/\(resource)/\(descriptor.digest)"
    }

    private static func createOrReplace(_ file: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        guard fm.createFile(atPath: file.path, contents: nil) else {
            throw ContainerizationError(.internalError, message: "cannot create file at path \(file.path)")
        }
        return file
    }
}
