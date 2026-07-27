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

/// Resolves the identity under which the engine's services register with launchd.
///
/// Upstream hardcodes the `com.apple.container.` prefix, which a sandboxed
/// embedder cannot use: the sandbox only permits mach-lookup of names that are
/// children of one of the process's app groups. An embedder overrides the
/// prefix (and provides its app group) via Info.plist keys carried by every
/// executable — the host app's `Info.plist`, and an embedded `__TEXT
/// __info_plist` section in each helper and the CLI, which those executables
/// need anyway to survive sandbox initialization outside an app context.
///
/// Resolution order, decided once per process:
/// 1. Environment (`CONTAINER_MACH_PREFIX` / `CONTAINER_APP_GROUP`) — tests
///    and development harnesses.
/// 2. `ContainerMachServicePrefix` / `ContainerAppGroup` in the main bundle's
///    info dictionary (covers both real .app bundles and embedded plists).
/// 3. The info dictionary of the enclosing `.app` bundle, for bare executables
///    in `Contents/MacOS` or `Contents/libexec` that lack their own keys.
/// 4. Upstream defaults (`com.apple.container.`, no app group).
public enum ServiceIdentity {
    /// The prefix for every launchd label and mach service name the engine
    /// registers or dials. Always ends with ".".
    public static let machPrefix: String = {
        let raw =
            resolve(infoKey: "ContainerMachServicePrefix", envKey: "CONTAINER_MACH_PREFIX")
            ?? "com.apple.container."
        return raw.hasSuffix(".") ? raw : raw + "."
    }()

    /// The security application group whose container holds engine state when
    /// the engine runs sandboxed. `nil` means the unsandboxed upstream layout.
    public static let appGroup: String? =
        resolve(infoKey: "ContainerAppGroup", envKey: "CONTAINER_APP_GROUP")

    /// Whether this build is running inside an embedder rather than as a
    /// standalone `container` install. True when either identity key was
    /// supplied, which only an embedder does.
    public static var isEmbedded: Bool {
        appGroup != nil || machPrefix != "com.apple.container."
    }

    /// The apiserver's launchd label and mach service name.
    public static var apiServerService: String { machPrefix + "apiserver" }

    private static func resolve(infoKey: String, envKey: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey], !env.isEmpty {
            return env
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String, !value.isEmpty {
            return value
        }
        if let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "", isDirectory: false) as URL?,
            let app = Bundle.appBundle(executablePath: FilePath(executable.path)),
            let value = app.object(forInfoDictionaryKey: infoKey) as? String, !value.isEmpty
        {
            return value
        }
        return nil
    }
}
