//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import CVersion
import Foundation

public struct ReleaseVersion {
    public static func singleLine(appName: String) -> String {
        var versionDetails: [String: String] = ["build": buildType()]
        versionDetails["commit"] = gitCommit().map { String($0.prefix(7)) } ?? "unspecified"
        let extras: String = versionDetails.map { "\($0): \($1)" }.sorted().joined(separator: ", ")

        return "\(appName) version \(version()) (\(extras))"
    }

    public static func buildType() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// The engine's own version.
    ///
    /// The enclosing `.app` bundle is only a sensible source when that bundle
    /// *is* the engine. Inside an embedder it is the host application, whose
    /// version has nothing to do with the engine's — reporting it made
    /// `container --version` claim the host app's number while the commit came
    /// from the engine, which is worse than either alone. When an embedder is
    /// configured, the version compiled in at build time is authoritative.
    public static func version() -> String {
        let compiled = get_release_version().map { String(cString: $0) }
        if ServiceIdentity.isEmbedded {
            return compiled ?? "0.0.0"
        }
        let appBundle = Bundle.appBundle(executablePath: CommandLine.executablePath)
        let bundleVersion = appBundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        return bundleVersion ?? compiled ?? "0.0.0"
    }

    public static func gitCommit() -> String? {
        get_git_commit().map { String(cString: $0) }
    }
}
