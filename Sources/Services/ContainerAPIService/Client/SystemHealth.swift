//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
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
        processNonce: String? = nil
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
    }
}
