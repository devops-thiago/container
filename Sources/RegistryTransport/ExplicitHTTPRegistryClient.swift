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
/// A push goes only to a registry on loopback (``LoopbackRegistry``), as Docker pushes over
/// plain HTTP to its default insecure registries, `127.0.0.0/8` and `::1`.
public final class ExplicitHTTPRegistryClient: ContentClient, @unchecked Sendable {
    enum TransportPolicyError: Error, CustomStringConvertible, Equatable, Sendable {
        case credentialBearingRedirect(statusCode: Int)
        /// A push names a registry off loopback: credentials go over plain HTTP to loopback alone.
        case pushOffLoopback(host: String)
        /// The registry named somewhere else to upload a blob to.
        case crossOriginUpload

        var statusCode: Int? {
            switch self {
            case .credentialBearingRedirect(let statusCode):
                statusCode
            case .pushOffLoopback, .crossOriginUpload:
                nil
            }
        }

        var description: String {
            switch self {
            case .credentialBearingRedirect(let statusCode):
                "insecure HTTP registry redirected a credential-bearing request; transfer stopped (HTTP status \(statusCode))"
            case .pushOffLoopback(let host):
                "credentials are sent over plain HTTP only to a registry on loopback (localhost, 127.0.0.0/8 or ::1); \(host) is not one"
            case .crossOriginUpload:
                "insecure HTTP registry named another origin to upload to; push stopped"
            }
        }
    }

    private let client: HTTPClient
    private let base: URLComponents
    private let authentication: any Authentication
    /// The most a manifest, index or config may be: what is held in memory. The registry's
    /// own word for the size is not trusted here; over plain HTTP anyone on the path could
    /// name gigabytes and have the images helper hold them.
    private let bufferSize: Int
    private let idleTimeout: Duration

    public convenience init(
        reference: String,
        authentication: any Authentication,
        bufferSize: Int = 4 * 1_048_576,
        idleTimeout: Duration = .seconds(30)
    ) throws {
        let ref = try Reference.parse(reference)
        guard let domain = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "invalid domain for image reference \(reference)")
        }
        guard let url = URL(string: "http://\(domain)"), let host = url.host else {
            throw ContainerizationError(.invalidArgument, message: "invalid HTTP registry \(domain)")
        }
        self.init(host: host, port: url.port, authentication: authentication, bufferSize: bufferSize, idleTimeout: idleTimeout)
    }

    /// - Parameter idleTimeout: how long the registry may send nothing before the transfer is
    ///   given up. It runs between reads, so a slow transfer that keeps arriving is never cut
    ///   short; a peer that has gone quiet no longer holds a pull for ever.
    public init(
        host: String,
        port: Int?,
        authentication: any Authentication,
        bufferSize: Int = 4 * 1_048_576,
        idleTimeout: Duration = .seconds(30)
    ) {
        var base = URLComponents()
        base.scheme = "http"
        // An IPv6 literal goes in brackets, which a URL's host drops.
        if host.contains(":"), !host.hasPrefix("[") {
            base.encodedHost = "[\(host)]"
        } else {
            base.host = host
        }
        base.port = port
        self.base = base
        self.authentication = authentication
        self.bufferSize = bufferSize
        self.idleTimeout = idleTimeout

        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(30), read: TimeAmount(idleTimeout))
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
        var target = URLComponents()
        target.path = path
        return try await makeRequest(components: target, method: method, headers: headers)
    }

    /// A request to the path and query of `target` on this client's origin, whatever else
    /// `target` names.
    func makeRequest(
        components target: URLComponents,
        method: HTTPMethod = .GET,
        headers: [(String, String)] = []
    ) async throws -> HTTPClientRequest {
        var components = base
        components.percentEncodedPath = target.percentEncodedPath
        components.percentEncodedQuery = target.percentEncodedQuery
        guard let url = components.url?.absoluteString else {
            throw ContainerizationError(.invalidArgument, message: "invalid registry path \(target.path)")
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
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, deadline: .distantFuture)
        } catch {
            throw silence(error, path: path)
        }
        try Self.rejectRedirect(statusCode: Int(response.status.code))
        return response
    }

    /// A read that timed out, in words: the registry stopped sending.
    private func silence(_ error: any Error, path: String) -> any Error {
        guard let clientError = error as? HTTPClientError, clientError == .readTimeout else { return error }
        return ContainerizationError(
            .timeout,
            message: "the registry sent nothing for \(Int(idleTimeout.components.seconds)) seconds while \(path) was being fetched",
            cause: error)
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
        // A fixed ceiling: a manifest or config is kilobytes, and the registry's own size is
        // what a bound is for, not what sets it.
        do {
            let body = try await response.body.collect(upTo: bufferSize)
            return Data(body.readableBytesView)
        } catch is NIOTooManyBytesError {
            throw ContainerizationError(
                .invalidArgument,
                message: "the registry's answer for \(path) is larger than \(bufferSize) bytes, more than any manifest or config")
        } catch {
            throw silence(error, path: path)
        }
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
        do {
            for try await buffer in response.body {
                let data = Data(buffer.readableBytesView)
                // The digest check afterwards would reject a blob that is not what its
                // descriptor says, but only once the disk had taken it. The surplus is
                // refused before it is written.
                guard received + Int64(data.count) <= descriptor.size else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "the registry sent more than the \(descriptor.size) bytes its descriptor gives for \(descriptor.digest)")
                }
                try handle.write(contentsOf: data)
                hasher.update(data: data)
                received += Int64(data.count)
                await progress?([.addSize(Int64(data.count))])
            }
        } catch {
            throw silence(error, path: path)
        }
        try handle.synchronize()
        return (received, hasher.finalize())
    }

    /// Uploads one blob or manifest, as `RegistryClient` does over HTTPS: nothing is sent when
    /// the registry has it already, a blob goes through an upload session, and a manifest is
    /// put under `tag`. Only to a registry on loopback, and only to the origin it was made for:
    /// an upload location elsewhere stops the push before the content or the credential goes
    /// there.
    public func push<T: Sendable & AsyncSequence>(
        name: String,
        ref tag: String,
        descriptor: Descriptor,
        streamGenerator: () throws -> T,
        progress: ProgressHandler?
    ) async throws where T.Element == ByteBuffer {
        let host = base.host ?? ""
        guard LoopbackRegistry.isLoopback(host) else {
            throw TransportPolicyError.pushOffLoopback(host: LoopbackRegistry.host(of: host))
        }
        guard !descriptor.mediaType.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "missing media type for descriptor \(descriptor.digest)")
        }
        let manifest = Self.manifestTypes.contains(descriptor.mediaType)
        let existing = manifest ? "/v2/\(name)/manifests/\(Self.manifestObject(tag: tag, descriptor: descriptor))" : "/v2/\(name)/blobs/\(descriptor.digest)"

        let head = try await execute(path: existing, method: .HEAD, headers: [("Accept", "\(descriptor.mediaType), */*")])
        switch head.status {
        case .ok:
            // An index under a tag is there only when the tag names this digest.
            if !manifest || existing.hasSuffix("/\(descriptor.digest)") || head.headers.first(name: "Docker-Content-Digest") == descriptor.digest {
                throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
            }
        case .notFound:
            break
        default:
            throw invalidStatus(head, path: existing)
        }

        var target = URLComponents()
        var headers: [(String, String)]
        if manifest {
            target.path = existing
            headers = [("Content-Type", descriptor.mediaType)]
        } else {
            let start = "/v2/\(name)/blobs/uploads/"
            let session = try await execute(path: start, method: .POST)
            switch session.status {
            case .ok, .accepted, .noContent:
                break
            case .created:
                throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
            default:
                throw invalidStatus(session, path: start)
            }
            guard let location = session.headers.first(name: "Location") else {
                throw ContainerizationError(.invalidArgument, message: "missing required header Location")
            }
            target = try uploadTarget(location)
            target.queryItems = (target.queryItems ?? []) + [URLQueryItem(name: "digest", value: descriptor.digest)]
            headers = [("Content-Type", "application/octet-stream")]
        }

        var request = try await makeRequest(components: target, method: .PUT, headers: headers)
        request.body = .stream(try streamGenerator(), length: .known(descriptor.size))
        let path = target.path
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, deadline: .distantFuture)
        } catch {
            throw silence(error, path: path)
        }
        try Self.rejectRedirect(statusCode: Int(response.status.code))
        switch response.status {
        case .ok, .created, .noContent:
            break
        default:
            throw invalidStatus(response, path: path)
        }
        guard response.headers.first(name: "Docker-Content-Digest") == descriptor.digest else {
            throw ContainerizationError(.internalError, message: "digest mismatch")
        }
    }

    /// Where an upload goes: the path and query `location` names, on this client's own origin.
    /// A relative location is resolved here; an absolute one must name this origin.
    func uploadTarget(_ location: String) throws -> URLComponents {
        guard let named = URLComponents(string: location) else {
            throw ContainerizationError(.invalidArgument, message: "invalid upload location")
        }
        if named.scheme != nil || named.host != nil {
            let sameOrigin =
                named.scheme?.lowercased() == base.scheme
                && named.host?.lowercased() == base.host?.lowercased()
                && (named.port ?? 80) == (base.port ?? 80)
            guard sameOrigin else { throw TransportPolicyError.crossOriginUpload }
        }
        var target = URLComponents()
        target.percentEncodedPath = named.percentEncodedPath
        target.percentEncodedQuery = named.percentEncodedQuery
        return target
    }

    /// Where a push puts a manifest. The index goes under the tag; the image manifests it
    /// names go under their own digests, which is how the index refers to them, so the tag
    /// never names one of them on the way. So does an index when the push names no tag, or a
    /// digest, which fits only the content it is the digest of.
    static func manifestObject(tag: String, descriptor: Descriptor) -> String {
        let index = descriptor.mediaType == MediaTypes.index || descriptor.mediaType == MediaTypes.dockerManifestList
        return !index || tag.isEmpty || tag.contains(":") || tag.contains("@") ? descriptor.digest : tag
    }

    private func invalidStatus(_ response: HTTPClientResponse, path: String) -> RegistryClient.Error {
        RegistryClient.Error.invalidStatus(url: base.string.map { $0 + path } ?? path, response.status, reason: nil)
    }

    private static let manifestTypes = [
        MediaTypes.dockerManifest,
        MediaTypes.dockerManifestList,
        MediaTypes.imageManifest,
        MediaTypes.index,
    ]

    private func resourcePath(name: String, descriptor: Descriptor, forceBlob: Bool = false) -> String {
        let resource = !forceBlob && Self.manifestTypes.contains(descriptor.mediaType) ? "manifests" : "blobs"
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
