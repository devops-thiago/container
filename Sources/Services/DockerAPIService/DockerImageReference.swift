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

/// An image reference in Docker's normal form, split into the parts Docker compares.
///
/// `alpine` is `docker.io/library/alpine:latest`, `ghcr.io/org/app@sha256:…` keeps its
/// registry. The familiar form is the one Docker prints: the Docker Hub registry and its
/// `library/` left out.
public struct DockerImageReference: Sendable, Hashable, CustomStringConvertible {
    public static let hubDomain = "docker.io"

    public let domain: String
    /// The repository path within the registry: `library/alpine`, `org/app`.
    public let path: String
    public let tag: String?
    public let digest: String?

    /// Parses `text`. A reference with neither tag nor digest gets `latest` when
    /// `defaultTag` is set, as dockerd reads one.
    public init(_ text: String, defaultTag: Bool = true) throws(DockerAPIError) {
        var name = text
        var tag: String?
        var digest: String?
        if let at = name.firstIndex(of: "@") {
            digest = String(name[name.index(after: at)...])
            name = String(name[..<at])
        }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            tag = String(name[name.index(after: colon)...])
            name = String(name[..<colon])
        }
        guard DockerPullReference.isValidName(name) else {
            throw .badRequest("invalid reference format: \(text)")
        }
        if let tag, !DockerPullReference.isValidTag(tag) {
            throw .badRequest("invalid reference format: \(text)")
        }
        if let digest, !DockerPullReference.isValidDigest(digest) {
            throw .badRequest("invalid reference format: \(text)")
        }
        let components = name.split(separator: "/").map(String.init)
        let hasDomain = components.count > 1 && (components[0].contains(".") || components[0].contains(":") || components[0] == "localhost")
        var domain = hasDomain ? components[0] : Self.hubDomain
        if ["index.docker.io", "registry-1.docker.io"].contains(domain) {
            domain = Self.hubDomain
        }
        var path = hasDomain ? components.dropFirst().joined(separator: "/") : name
        if domain == Self.hubDomain && !path.contains("/") {
            path = "library/" + path
        }
        self.domain = domain
        self.path = path
        self.tag = tag ?? (digest == nil && defaultTag ? "latest" : nil)
        self.digest = digest
    }

    /// The repository with its registry: `docker.io/library/alpine`.
    public var name: String { "\(domain)/\(path)" }

    /// The repository as Docker prints it: `alpine`, `org/app`, `ghcr.io/org/app`.
    public var familiarName: String {
        guard domain == Self.hubDomain else { return name }
        return path.hasPrefix("library/") ? String(path.dropFirst("library/".count)) : path
    }

    var suffix: String {
        (tag.map { ":" + $0 } ?? "") + (digest.map { "@" + $0 } ?? "")
    }

    /// The reference as Docker prints it: `alpine:latest`, `ghcr.io/org/app@sha256:…`.
    public var familiar: String { familiarName + suffix }

    /// The reference in full: `docker.io/library/alpine:latest`.
    public var normalized: String { name + suffix }

    public var description: String { normalized }

    /// The same repository with another tag and no digest.
    public func tagged(_ tag: String) -> DockerImageReference {
        DockerImageReference(domain: domain, path: path, tag: tag, digest: nil)
    }

    private init(domain: String, path: String, tag: String?, digest: String?) {
        self.domain = domain
        self.path = path
        self.tag = tag
        self.digest = digest
    }
}
