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

import ContainerVersion
import Foundation
import SystemPackage

public enum PathUtils {
    /// A temporary directory every engine process can reach.
    ///
    /// Sandboxed, each process has a temporary directory of its own inside its own container,
    /// which the others cannot open: a tar the CLI stages for the images helper, or one the
    /// helper writes for the CLI to stream, has to live somewhere both can see, and the group
    /// container is that place. Unsandboxed there is one temporary directory for everyone.
    public static func sharedTemporaryDirectory() throws -> URL {
        guard let group = BaseConfigPath.groupContainer() else {
            return FileManager.default.temporaryDirectory
        }
        let directory = URL(fileURLWithPath: group.appending("tmp").string, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where engine services publish sockets for clients outside the engine:
    /// `<group container>/run`, or `run` beside the app root without an app group.
    ///
    /// Created 0700 for this user. A symlink, something other than a directory, or a
    /// directory another user owns is refused rather than used, because whoever controls
    /// this directory controls who reaches what is published in it.
    public static func runDirectory() throws -> URL {
        try runDirectory(in: BaseConfigPath.groupContainer() ?? BaseConfigPath.appRoot.basePath().removingLastComponent())
    }

    static func runDirectory(in base: FilePath) throws -> URL {
        let path = base.appending("run").string
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw POSIXError(.EPERM)
        }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public enum BaseConfigPath {
        case home
        case appRoot
        case installRoot

        public func basePath(env: [String: String] = ProcessInfo.processInfo.environment) -> FilePath {
            switch self {
            case .home:
                // When an app group is configured (sandboxed embedding), the
                // group container is the only place every engine process —
                // app, agents, spawned runtimes, and the Terminal-run CLI —
                // can all read and write, so config lives there too.
                if let group = Self.groupContainer() {
                    return group.appending("Library/Application Support/config")
                }
                let configHome: String
                if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
                    configHome = xdg
                } else {
                    configHome = NSHomeDirectory() + "/.config"
                }
                return FilePath(configHome).appending("container")
            case .appRoot:
                if let envPath = env["CONTAINER_APP_ROOT"], !envPath.isEmpty {
                    return FilePath(envPath)
                }
                if let group = Self.groupContainer() {
                    return group.appending("Library/Application Support/engine")
                }
                let appSupportURL = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!.appendingPathComponent("com.apple.container")
                return FilePath(appSupportURL.path(percentEncoded: false))
            case .installRoot:
                if let envPath = env["CONTAINER_INSTALL_ROOT"], !envPath.isEmpty {
                    return FilePath(envPath)
                }
                // Use the kernel-recorded executable path (via _NSGetExecutablePath)
                // rather than argv[0]: when the binary is invoked through PATH (e.g.
                // `container ...`), argv[0] is just the basename and resolves to an
                // empty FilePath, which FileManager treats as CWD-relative.
                let installRootPath = CommandLine.executablePath
                    .removingLastComponent()
                    .removingLastComponent()
                return installRootPath
            }
        }

        /// The group container root when the engine is configured with an app
        /// group (see ``ServiceIdentity/appGroup``), else `nil`.
        ///
        /// `containerURL(forSecurityApplicationGroupIdentifier:)` is
        /// deterministic (`~/Library/Group Containers/<group>`) and creates
        /// the directory on first use for entitled processes.
        static func groupContainer() -> FilePath? {
            guard let group = ServiceIdentity.appGroup else { return nil }
            guard
                let url = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: group)
            else { return nil }
            return FilePath(url.path(percentEncoded: false))
        }
    }
}
