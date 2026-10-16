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
import SystemPackage

/// Snapshot of the health of container services and resources.
public struct SystemHealth: Sendable, Codable {
    public static let currentLifecycleProtocolVersion: UInt64 = 1

    /// The full pathname of the application data root.
    public let appRoot: URL

    /// The full pathname of the application install root.
    public let installRoot: URL

    /// The full pathname of the log root.
    public let logRoot: FilePath?

    /// The release version of the container services.
    public let apiServerVersion: String

    /// The Git commit ID for the container services.
    public let apiServerCommit: String

    /// The build type of the API server (debug|release).
    public let apiServerBuild: String

    /// The app name label returned by the server.
    public let apiServerAppName: String

    /// The safe-shutdown protocol version, absent for legacy API servers.
    public let lifecycleProtocolVersion: UInt64?

    /// The launch lifecycle generation, absent for legacy API servers.
    public let lifecycleGeneration: String?

    /// The unique nonce for this API-server process, absent for legacy API servers.
    public let processNonce: String?

    /// How many observable changes this API-server process has made: containers (their
    /// state and health included), networks and volumes. Only comparable for one
    /// `processNonce`. Absent for API servers that do not count.
    public let stateGeneration: UInt64?

    /// What this API server can do that an older one cannot (`APIServerCapability`); empty for
    /// API servers that do not say.
    public let capabilities: Set<String>

    /// Whether this API server has `capability`.
    public func supports(_ capability: APIServerCapability) -> Bool {
        capabilities.contains(capability.rawValue)
    }

    public init(
        appRoot: URL,
        installRoot: URL,
        logRoot: FilePath?,
        apiServerVersion: String,
        apiServerCommit: String,
        apiServerBuild: String,
        apiServerAppName: String,
        lifecycleProtocolVersion: UInt64? = nil,
        lifecycleGeneration: String? = nil,
        processNonce: String? = nil,
        stateGeneration: UInt64? = nil,
        capabilities: Set<String> = []
    ) {
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.logRoot = logRoot
        self.apiServerVersion = apiServerVersion
        self.apiServerCommit = apiServerCommit
        self.apiServerBuild = apiServerBuild
        self.apiServerAppName = apiServerAppName
        self.lifecycleProtocolVersion = lifecycleProtocolVersion
        self.lifecycleGeneration = lifecycleGeneration
        self.processNonce = processNonce
        self.stateGeneration = stateGeneration
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case appRoot, installRoot, logRoot, apiServerVersion, apiServerCommit, apiServerBuild, apiServerAppName
        case lifecycleProtocolVersion, lifecycleGeneration, processNonce, stateGeneration, capabilities
    }

    /// A health snapshot written before capabilities were reported decodes with none, as the
    /// other fields added since decode as absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appRoot = try container.decode(URL.self, forKey: .appRoot)
        self.installRoot = try container.decode(URL.self, forKey: .installRoot)
        self.logRoot = try container.decodeIfPresent(FilePath.self, forKey: .logRoot)
        self.apiServerVersion = try container.decode(String.self, forKey: .apiServerVersion)
        self.apiServerCommit = try container.decode(String.self, forKey: .apiServerCommit)
        self.apiServerBuild = try container.decode(String.self, forKey: .apiServerBuild)
        self.apiServerAppName = try container.decode(String.self, forKey: .apiServerAppName)
        self.lifecycleProtocolVersion = try container.decodeIfPresent(UInt64.self, forKey: .lifecycleProtocolVersion)
        self.lifecycleGeneration = try container.decodeIfPresent(String.self, forKey: .lifecycleGeneration)
        self.processNonce = try container.decodeIfPresent(String.self, forKey: .processNonce)
        self.stateGeneration = try container.decodeIfPresent(UInt64.self, forKey: .stateGeneration)
        self.capabilities = try container.decodeIfPresent(Set<String>.self, forKey: .capabilities) ?? []
    }
}

/// What an API server can do that an older one cannot. A client checks before it uses a
/// route, rather than sending a request an older server would not answer.
public enum APIServerCapability: String, Sendable, CaseIterable {
    /// `XPCRoute.containerEvent`: a subscription to container events.
    case containerEvents
    /// `XPCRoute.containerUpdateLabels`: setting the labels the server allows to change.
    case containerLabels

    /// As the health check carries them.
    public static func encode(_ capabilities: [APIServerCapability]) -> String {
        capabilities.map(\.rawValue).joined(separator: ",")
    }

    public static func decode(_ text: String?) -> Set<String> {
        Set((text ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
}
