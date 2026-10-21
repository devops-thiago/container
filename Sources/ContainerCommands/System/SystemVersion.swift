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

import ArgumentParser
import ContainerAPIClient
import ContainerVersion
import DockerAPIService
import Foundation

extension Application {
    public struct SystemVersion: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Show version information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: FormatOrTemplate = .format(.table)

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func validate() throws {
            _ = try format.dockerTemplate()
        }

        public func run() async throws {
            if let template = try format.dockerTemplate() {
                try await Self.printDockerVersion(template)
                return
            }
            guard case .format(let format) = format else { return }
            let cliInfo = VersionInfo(
                version: ReleaseVersion.version(),
                buildType: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container"
            )

            // Try to get API server version info
            let serverInfo: VersionInfo?
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                serverInfo = VersionInfo(
                    version: health.apiServerVersion,
                    buildType: health.apiServerBuild,
                    commit: health.apiServerCommit,
                    appName: health.apiServerAppName
                )
            } catch {
                serverInfo = nil
            }

            let versions = [cliInfo, serverInfo].compactMap { $0 }

            try Output.render(payload: versions, format: format) {
                Self.versionTable(versions)
            }
        }

        /// `docker version --format`: the client and the engine as Docker's CLI reports them, the
        /// engine with the versions the Docker API reports (`GET /version`). Tools read the
        /// engine's API version from it (`{{.Server.ApiVersion}}`) to tell what it speaks.
        static func printDockerVersion(_ template: DockerTemplate) async throws {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
            let report = DockerVersionReport(
                Client: .init(version: ReleaseVersion.version(), commit: ReleaseVersion.gitCommit() ?? ""),
                Server: SystemRoutes.VersionBody(engineVersion: health.apiServerVersion, engineCommit: health.apiServerCommit))
            print(try template.render(report))
        }

        private static func versionTable(_ versions: [VersionInfo]) -> String {
            let header = ["COMPONENT", "VERSION", "BUILD", "COMMIT"]
            let rows = [header] + versions.map { [$0.appName, $0.version, $0.buildType, $0.commit] }
            return TableOutput(rows: rows).format()
        }
    }

    public struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
    }
}

/// What `docker version` reports, for its `--format` templates.
struct DockerVersionReport: Encodable {
    struct ClientBody: Encodable {
        struct PlatformBody: Encodable { let Name: String }
        let Platform: PlatformBody
        let Version: String
        let ApiVersion: String
        let DefaultAPIVersion: String
        let GitCommit: String
        let GoVersion: String
        let Os: String
        let Arch: String

        /// This CLI, at the API version the engine's Docker API speaks.
        init(version: String, commit: String) {
            Platform = PlatformBody(Name: "container")
            Version = version
            ApiVersion = DockerAPIVersion.current.description
            DefaultAPIVersion = DockerAPIVersion.current.description
            GitCommit = commit
            GoVersion = ""
            Os = "darwin"
            Arch = "arm64"
        }
    }

    let Client: ClientBody
    let Server: SystemRoutes.VersionBody
}
