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
import ContainerCompose
import ContainerVersion
import Foundation

struct ComposeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run the containers a compose file describes",
        discussion: """
            Reads compose.yaml (or compose.yml, docker-compose.yaml, docker-compose.yml) in \
            the current directory, with its override file when there is one, and runs each \
            service as a container on a network of the project's own. A service reaches \
            another by its name.

            A key the engine cannot honour stops the command and says which one, with its \
            line. `config --commands` prints the container commands a project comes to.

            EXAMPLES:
              Start a project in the background, see it, and take it down:
                $ container compose up -d
                $ container compose ps
                $ container compose down

              Use another file, another name, or a profile:
                $ container compose -f deploy/compose.yaml -p shop --profile debug up -d

              Follow the logs of two services:
                $ container compose logs -f web db

              Run a command in a service's container:
                $ container compose exec db psql -U postgres
            """,
        version: ReleaseVersion.singleLine(appName: "compose"),
        subcommands: [
            ComposeUp.self,
            ComposeDown.self,
            ComposePs.self,
            ComposeLogs.self,
            ComposeStart.self,
            ComposeStop.self,
            ComposeRestart.self,
            ComposePull.self,
            ComposeBuild.self,
            ComposeExec.self,
            ComposeConfig.self,
        ]
    )

    @Option(
        name: [.customShort("f"), .customLong("file")],
        help: .init("Compose file to read; repeat to merge several, in order", valueName: "path"))
    var files: [String] = []

    @Option(name: [.customShort("p"), .customLong("project-name")], help: .init("Project name (default: the directory's)", valueName: "name"))
    var projectName: String?

    @Option(name: .customLong("project-directory"), help: .init("What relative paths in the files are relative to (default: the first file's directory)", valueName: "path"))
    var projectDirectory: String?

    @Option(name: .customLong("profile"), help: .init("Profile to turn on; repeat for several", valueName: "name"))
    var profiles: [String] = []

    @Option(name: .customLong("env-file"), help: .init("File of variables for the compose files, in place of .env", valueName: "path"))
    var envFiles: [String] = []

    /// Where compose was run. Sandboxed, this process starts in a folder of its own, and
    /// the shell's directory is the one the user means.
    private var workingDirectory: String { HostPath.absolute(".") }

    private var loaderOptions: ComposeLoader.Options {
        ComposeLoader.Options(
            files: files,
            workingDirectory: workingDirectory,
            projectDirectory: projectDirectory,
            projectName: projectName,
            profiles: profiles,
            envFiles: envFiles,
            // Sandboxed, only the folder compose was run in has been lent to this process.
            searchesParents: !ClientHostDirectory.isSandboxed)
    }

    /// Sandboxed, this process reads only what the engine lends it: the folders of the
    /// files it was pointed at, or, pointed at none, the folder compose runs in, which is
    /// where it then looks for one. A folder nobody named is not asked for.
    private func borrowFolders() async throws {
        var paths = files.filter { $0 != "-" }
        paths.append(contentsOf: envFiles)
        if let projectDirectory { paths.append(projectDirectory) }
        if files.isEmpty && projectDirectory == nil { paths.append(workingDirectory) }
        try await ClientHostDirectory.borrow(paths.map { HostPath.absolute($0) }, verb: "read")
    }

    /// The project the files describe.
    func definition() async throws -> ComposeDefinition {
        try await borrowFolders()
        return try ComposeLoader.load(loaderOptions)
    }

    /// The project planned for the services named, with what it will not do said on
    /// standard error.
    func plan(services: [String] = [], includesDependencies: Bool = true, reporter: ConsoleReporter) async throws -> ProjectPlan {
        let plan = try ProjectPlan.make(
            try await definition(), selection: .init(services: services, includesDependencies: includesDependencies))
        for warning in ComposeDiagnostic.lines(plan.warnings) {
            reporter.warn(warning)
        }
        return plan
    }

    /// The name of the project, for commands that work on what already runs: `-p`, or the
    /// name the files in this directory give it.
    func resolvedProjectName() async throws -> String {
        if let projectName, files.isEmpty, projectDirectory == nil {
            guard ComposeLoader.nameValid(projectName) else {
                throw ComposeError("'\(projectName)' is not a project name: lowercase letters, digits, '-' and '_', starting with a letter or digit")
            }
            return projectName
        }
        try await borrowFolders()
        return try ComposeLoader.projectName(loaderOptions)
    }
}
