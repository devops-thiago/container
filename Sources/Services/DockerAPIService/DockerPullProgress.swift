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

/// What the engine reports while it pulls. Sizes and counts are added as they become known,
/// in no particular order, so only their sums mean anything.
public enum DockerPullEvent: Sendable, Equatable {
    case addItems(Int)
    case addTotalItems(Int)
    case addSize(Int64)
    case addTotalSize(Int64)
    /// The content is here and is being unpacked.
    case extracting
}

/// One line of Docker's JSON message stream, in its field names.
public struct DockerProgressMessage: Encodable, Sendable, Equatable {
    public struct Detail: Encodable, Sendable, Equatable {
        public let current: Int64?
        public let total: Int64?
    }

    public struct ErrorDetail: Encodable, Sendable, Equatable {
        public let message: String
    }

    public let status: String?
    public let progressDetail: Detail?
    public let progress: String?
    public let id: String?
    public let errorDetail: ErrorDetail?
    public let error: String?

    public init(status: String? = nil, id: String? = nil, progressDetail: Detail? = nil, progress: String? = nil) {
        self.status = status
        self.id = id
        self.progressDetail = progressDetail
        self.progress = progress
        self.errorDetail = nil
        self.error = nil
    }

    private init(failure message: String) {
        status = nil
        id = nil
        progressDetail = nil
        progress = nil
        errorDetail = ErrorDetail(message: message)
        error = message
    }

    /// A failure after the head went out: the CLI reports the pull as failed with `message`.
    public static func failure(_ message: String) -> Self {
        Self(failure: message)
    }
}

/// An image reference as `images/create` takes it, split the ways the progress lines need.
public struct DockerPullReference: Sendable, Equatable {
    /// What the engine pulls: the name with its tag or digest.
    public let reference: String
    /// The repository as the `Pulling from` line names it: `library/alpine`, `org/app`.
    public let repository: String
    /// The tag, or the digest, being pulled.
    public let tagOrDigest: String
    /// The reference as Docker prints it in the final status: `alpine:3.22`, `ghcr.io/org/app:1`.
    public let familiar: String

    /// `fromImage` with the `tag` parameter, which the CLI sends apart. A tag that is a digest
    /// pins it; an absent tag is `latest`.
    public init(fromImage: String, tag: String?) throws(DockerAPIError) {
        var name = fromImage
        var tagged: String?
        var digest: String?
        if let at = name.firstIndex(of: "@") {
            digest = String(name[name.index(after: at)...])
            name = String(name[..<at])
        } else if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            tagged = String(name[name.index(after: colon)...])
            name = String(name[..<colon])
        }
        if let tag, !tag.isEmpty {
            if tag.contains(":") {
                digest = tag
                tagged = nil
            } else {
                tagged = tag
                digest = nil
            }
        }
        guard Self.isValidName(name) else {
            throw .badRequest("invalid reference format: \(fromImage)")
        }
        if let digest {
            guard Self.isValidDigest(digest) else { throw .badRequest("invalid reference format: digest \(digest)") }
        } else if let tagged {
            guard Self.isValidTag(tagged) else { throw .badRequest("invalid reference format: tag \(tagged)") }
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let hasDomain = components.count > 1 && (components[0].contains(".") || components[0].contains(":") || components[0] == "localhost")
        let domain = hasDomain ? components[0] : nil
        var path = hasDomain ? components.dropFirst().joined(separator: "/") : name
        let isDockerHub = domain == nil || domain == "docker.io" || domain == "index.docker.io" || domain == "registry-1.docker.io"
        if isDockerHub && !path.contains("/") {
            path = "library/" + path
        }
        let suffix = digest.map { "@" + $0 } ?? ":" + (tagged ?? "latest")
        reference = name + suffix
        repository = path
        tagOrDigest = digest ?? tagged ?? "latest"
        let shortPath = path.hasPrefix("library/") ? String(path.dropFirst("library/".count)) : path
        familiar = (isDockerHub ? shortPath : name) + suffix
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("//") else { return false }
        let components = name.split(separator: "/")
        for (index, component) in components.enumerated() {
            // The first component may be a registry host, with a port and capitals.
            let isHost = index == 0 && components.count > 1 && (component.contains(".") || component.contains(":") || component == "localhost")
            let allowed = isHost ? #/[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]+)?/# : #/[a-z0-9]+(?:[._-]+[a-z0-9]+)*/#
            guard component.wholeMatch(of: allowed) != nil else { return false }
        }
        return true
    }

    static func isValidTag(_ tag: String) -> Bool {
        tag.wholeMatch(of: #/[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}/#) != nil
    }

    static func isValidDigest(_ digest: String) -> Bool {
        digest.wholeMatch(of: #/[a-z0-9]+(?:[+._-][a-z0-9]+)*:[a-zA-Z0-9=_-]{32,}/#) != nil
    }
}

/// The engine's pull progress, summed, as Docker progress lines.
///
/// The engine counts the whole image rather than each layer, so one line under the tag's id
/// carries it, where dockerd has one line per layer. The CLI draws the bar from
/// `progressDetail`; `progress` is the same in text, for clients that print it.
public struct DockerPullProgress: Sendable, Equatable {
    public private(set) var items = 0
    public private(set) var totalItems = 0
    public private(set) var size: Int64 = 0
    public private(set) var totalSize: Int64 = 0
    public private(set) var extracting = false

    public init() {}

    public mutating func apply(_ events: [DockerPullEvent]) {
        for event in events {
            switch event {
            case .addItems(let count): items += count
            case .addTotalItems(let count): totalItems += count
            case .addSize(let bytes): size += bytes
            case .addTotalSize(let bytes): totalSize += bytes
            case .extracting: extracting = true
            }
        }
    }

    /// The line for the progress so far, under `id`.
    public func message(id: String) -> DockerProgressMessage {
        if extracting {
            return DockerProgressMessage(status: "Extracting", id: id)
        }
        let total = totalSize > 0 ? totalSize : nil
        // Sums arrive out of order: what is done is never shown past what there is.
        let current = total.map { min(size, $0) } ?? size
        return DockerProgressMessage(
            status: "Downloading", id: id, progressDetail: .init(current: current, total: total), progress: Self.bar(current: current, total: total))
    }

    /// `[=========>          ]  1.2MB/3.4MB`, 50 cells wide, or the size alone without a total.
    public static func bar(current: Int64, total: Int64?) -> String {
        guard let total, total > 0 else { return humanSize(current) }
        let filled = Int(min(50, max(0, current * 50 / total)))
        let cells = String(repeating: "=", count: filled) + (filled < 50 ? ">" + String(repeating: " ", count: 49 - filled) : "")
        return "[\(cells)] \(humanSize(current))/\(humanSize(total))"
    }

    /// Decimal units with four significant digits, as Docker writes sizes: `3.62MB`, `512B`.
    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        var text = String(format: "%.4g", value)
        if text.contains("e") { text = String(format: "%.0f", value) }
        return text + units[unit]
    }
}
