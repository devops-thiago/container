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
import Testing

@testable import ContainerCompose

/// `include`, held to what Docker Compose 5.6.1 prints for the same files with
/// `docker compose config`.
struct IncludeTests {
    private func service(_ name: String, in definition: ComposeDefinition) throws -> ComposeService {
        try #require(definition.file.services.first { $0.name == name })
    }

    private func bindSources(_ service: ComposeService) -> [String] {
        service.mounts.compactMap {
            if case .bind(let source) = $0.kind { return source }
            return nil
        }
    }

    @Test
    func anIncludedFileIsReadInItsOwnDirectoryWithItsOwnVariables() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include:
                  - infra/compose.yaml
                services:
                  app:
                    image: alpine
                    environment:
                      - V=${V:-unset}
                      - P=${P:-unset}
                      - PASS
                """,
                ".env": "V=parent\nPASS=parentpass\n",
                "infra/compose.yaml": """
                name: incname
                services:
                  db:
                    image: "img:${V:-unset}-${I:-unset}"
                    env_file: [db.env]
                    environment:
                      - PASS
                      - IONLY
                    volumes: ["./data:/data"]
                    build: {}
                """,
                "infra/.env": "V=included\nI=inc\nIONLY=inconly\nPASS=incpass\n",
                "infra/db.env": "A=1\nFROM_INCLUDE=${I}\n",
            ], named: "shop")
        let definition = try project.load()

        #expect(definition.name == "shop", "an included file's name is not the project's")
        #expect(definition.configFiles == ["\(project.path)/compose.yaml"])
        #expect(definition.includedFiles == ["\(project.path)/infra/compose.yaml"])

        let app = try service("app", in: definition)
        #expect(app.environment == ["V": "parent", "P": "unset", "PASS": "parentpass"])

        let db = try service("db", in: definition)
        #expect(db.image == "img:parent-inc", "the including project's variables win over the included .env")
        #expect(db.environment == ["A": "1", "FROM_INCLUDE": "inc", "IONLY": "inconly", "PASS": "parentpass"])
        #expect(bindSources(db) == ["\(project.path)/infra/data"])
        #expect(db.build?.context == "\(project.path)/infra")
    }

    @Test
    func theLongFormMergesItsFilesAndNamesADirectoryAndEnvFiles() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include:
                  - path: [long/base.yaml, long/over.yaml]
                    project_directory: pd
                    env_file: long/x.env
                services:
                  app:
                    image: alpine
                """,
                "long/base.yaml": """
                services:
                  lg:
                    image: "l:${X:-unset}"
                    volumes: ["./rel:/rel"]
                    env_file: [lg.env]
                """,
                "long/over.yaml": """
                services:
                  lg:
                    environment: [O=1]
                """,
                "long/x.env": "X=fromx\n",
                "pd/lg.env": "L=1\n",
            ], named: "shop")
        let definition = try project.load()
        let lg = try service("lg", in: definition)
        #expect(lg.image == "l:fromx")
        #expect(lg.environment == ["O": "1", "L": "1"])
        #expect(bindSources(lg) == ["\(project.path)/pd/rel"], "paths in the files are relative to project_directory")
        #expect(definition.includedFiles == ["\(project.path)/long/base.yaml", "\(project.path)/long/over.yaml"])
    }

    @Test
    func anIncludedFileIncludesInTurnFromItsOwnDirectory() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include: [infra/compose.yaml]
                services:
                  app: {image: alpine}
                """,
                "infra/compose.yaml": """
                include: [deeper/c.yaml]
                services:
                  db: {image: db}
                """,
                "infra/.env": "I=inc\n",
                "infra/deeper/c.yaml": """
                services:
                  deep:
                    image: "deep:${I:-unset}"
                    build: .
                    volumes: ["./d:/d"]
                """,
            ], named: "shop")
        let definition = try project.load()
        #expect(definition.file.services.map(\.name) == ["app", "db", "deep"])
        let deep = try service("deep", in: definition)
        #expect(deep.image == "deep:inc", "what includes a file hands its variables down")
        #expect(deep.build?.context == "\(project.path)/infra/deeper")
        #expect(bindSources(deep) == ["\(project.path)/infra/deeper/d"])
    }

    @Test
    func theIncludingFilesMergeOverAnIncludeAndAnEarlierIncludeOverALaterOne() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include: [x/inc.yaml, y/inc.yaml]
                services:
                  db:
                    environment: {FROM_MAIN: "1"}
                    ports: ["82:82"]
                """,
                "x/inc.yaml": """
                services:
                  db:
                    image: one
                    environment: {FROM_X: "1"}
                    ports: ["80:80"]
                    volumes: ["v1:/v"]
                volumes:
                  v1: {}
                """,
                "y/inc.yaml": """
                services:
                  db:
                    image: three
                    environment: {FROM_Y: "1"}
                    ports: ["81:81"]
                volumes:
                  v1: {name: yname}
                """,
                "over.yaml": """
                services:
                  db:
                    image: four
                """,
            ], named: "shop")
        let definition = try project.load()
        let db = try service("db", in: definition)
        #expect(db.image == "one")
        #expect(db.environment == ["FROM_MAIN": "1", "FROM_X": "1", "FROM_Y": "1"])
        #expect(db.ports.map(\.target) == ["81", "80", "82"])
        #expect(definition.file.volumes.first { $0.key == "v1" }?.name == "yname")

        let overridden = try project.load(files: ["compose.yaml", "over.yaml"])
        #expect(try service("db", in: overridden).image == "four", "a second -f merges over what the first one includes")

        // A file is merged with what it includes before it merges over the files before it.
        try project.write("services:\n  db: {image: first}\n", to: "first.yaml")
        try project.write("include: [y/inc.yaml]\nservices:\n  app: {image: alpine}\n", to: "second.yaml")
        #expect(try service("db", in: project.load(files: ["first.yaml", "second.yaml"])).image == "three")
        #expect(try service("db", in: project.load(files: ["second.yaml", "first.yaml"])).image == "first")
    }

    @Test
    func includePathsAreRelativeToTheProjectDirectoryAndTakeVariables() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include:
                  - ${WHERE:-x}/inc.yaml
                services:
                  app: {image: alpine}
                """,
                "x/inc.yaml": "services:\n  db: {image: here}\n",
                "pd/x/inc.yaml": "services:\n  db: {image: frompd}\n",
                "pd/z/inc.yaml": "services:\n  db: {image: fromz}\n",
            ], named: "shop")
        #expect(try service("db", in: project.load()).image == "here")
        #expect(try service("db", in: project.load(files: ["compose.yaml"], projectDirectory: "pd")).image == "frompd")
        #expect(try service("db", in: project.load(files: ["compose.yaml"], environment: ["WHERE": "z"], projectDirectory: "pd")).image == "fromz")
    }

    @Test
    func aFileOfNothingButIncludesIsAProject() throws {
        let project = try TemporaryProject(
            ["compose.yaml": "include: [x/inc.yaml]\n", "x/inc.yaml": "services:\n  db: {image: one}\n"], named: "shop")
        #expect(try project.load().file.services.map(\.name) == ["db"])
    }

    @Test
    func whatCannotBeIncludedIsRefused() throws {
        let project = try TemporaryProject(
            [
                "string.yaml": "include: x/inc.yaml\nservices:\n  a: {image: a}\n",
                "missing.yaml": "include: [nope.yaml]\nservices:\n  a: {image: a}\n",
                "envfile.yaml": "include:\n  - path: x/inc.yaml\n    env_file: nope.env\nservices:\n  a: {image: a}\n",
                "nopath.yaml": "include:\n  - project_directory: x\nservices:\n  a: {image: a}\n",
                "remote.yaml": "include: ['oci://docker.io/acme/stack:1']\nservices:\n  a: {image: a}\n",
                "cycle.yaml": "include: [cycle2.yaml]\nservices:\n  a: {image: a}\n",
                "cycle2.yaml": "include: [cycle.yaml]\nservices:\n  b: {image: b}\n",
                "x/inc.yaml": "services:\n  db: {image: one}\n",
            ], named: "shop")
        func failure(_ file: String) -> [String] { loadFailure { try project.load(files: [file]) } }
        #expect(failure("string.yaml") == ["string.yaml:1:10: include: expected a list, found a value"])
        #expect(failure("missing.yaml") == ["missing.yaml:1:11: include: the included file \(project.path)/nope.yaml does not exist"])
        #expect(failure("envfile.yaml") == ["envfile.yaml:2:5: include: the env file \(project.path)/nope.env does not exist"])
        #expect(failure("nopath.yaml") == ["nopath.yaml:2:5: include[0].path: an include names the file to read"])
        #expect(
            failure("remote.yaml") == [
                "remote.yaml:1:11: include: oci://docker.io/acme/stack:1: a compose file fetched from a registry or a repository cannot be included"
            ])
        #expect(failure("cycle.yaml") == ["cycle2.yaml:1:11: include: the files include each other: cycle.yaml includes cycle2.yaml includes cycle.yaml"])
    }

    @Test
    func aLinkToAFileBeingReadIsACycleAndAFileThatMayNotBeLookedAtIsNotAbsent() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "include: [linked/again.yaml]\nservices:\n  a: {image: a}\n",
                "locked.yaml": "include: [closed/inc.yaml]\nservices:\n  a: {image: a}\n",
                "closed/inc.yaml": "services:\n  db: {image: one}\n",
            ], named: "shop")
        try project.makeDirectory("linked")
        try FileManager.default.createSymbolicLink(
            atPath: "\(project.path)/linked/again.yaml", withDestinationPath: "\(project.path)/compose.yaml")
        #expect(
            loadFailure { try project.load() } == [
                "compose.yaml:1:11: include: the files include each other: compose.yaml includes linked/again.yaml"
            ])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(project.path)/closed")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(project.path)/closed") }
        #expect(
            loadFailure { try project.load(files: ["locked.yaml"]) } == [
                "locked.yaml:1:11: include: \(project.path)/closed/inc.yaml could not be read: Permission denied"
            ])
        // The refusal names the file, for an embedder that can ask for its folder.
        do {
            _ = try project.load(files: ["locked.yaml"])
            Issue.record("a file that may not be looked at was loaded")
        } catch let error as ComposeError {
            #expect(error.deniedPath == "\(project.path)/closed/inc.yaml")
        }
        // The same when the folder can be looked into and the file itself cannot be opened.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(project.path)/closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(project.path)/closed/inc.yaml")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(project.path)/closed/inc.yaml") }
        do {
            _ = try project.load(files: ["locked.yaml"])
            Issue.record("a file that may not be opened was loaded")
        } catch let error as ComposeError {
            #expect(error.deniedPath == "\(project.path)/closed/inc.yaml")
        }
        // A file that is not there is not one to ask for.
        try project.write("include: [nowhere/inc.yaml]\nservices:\n  a: {image: a}\n", to: "absent.yaml")
        do {
            _ = try project.load(files: ["absent.yaml"])
            Issue.record("a missing file was loaded")
        } catch let error as ComposeError {
            #expect(error.deniedPath == nil)
        }
    }

    @Test
    func whatIsWrongInAnIncludedFileIsReportedThere() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "include: [x/inc.yaml]\nservices:\n  a: {image: a}\n",
                "x/inc.yaml": "services:\n  db:\n    image: one\n    nonsense: 1\n",
            ], named: "shop")
        #expect(loadFailure { try project.load() } == ["x/inc.yaml:4:5: services.db.nonsense: not a compose key"])
    }

    /// A chain of files, each including the next, `levels` includes deep.
    private func chain(_ levels: Int, references: Int = 1) throws -> TemporaryProject {
        var files: [String: String] = [:]
        for level in 0...levels {
            let name = level == 0 ? "compose.yaml" : "f\(level).yaml"
            let include =
                level < levels
                ? "include: [" + Array(repeating: "f\(level + 1).yaml", count: references).joined(separator: ", ") + "]\n" : ""
            files[name] = include + "services:\n  s\(level): {image: i}\n"
        }
        return try TemporaryProject(files, named: "deep")
    }

    @Test
    func includesNestAsDeepAsTheLimitAndAreRefusedPastIt() async throws {
        let allowed = try chain(ComposeInput.maximumIncludeDepth)
        let definition = try allowed.load()
        #expect(definition.file.services.count == ComposeInput.maximumIncludeDepth + 1)
        #expect(definition.includedFiles.count == ComposeInput.maximumIncludeDepth)

        let deeper = try chain(ComposeInput.maximumIncludeDepth + 1)
        #expect(
            loadFailure { try deeper.load() } == [
                "f\(ComposeInput.maximumIncludeDepth).yaml:1:11: include: include is nested more than \(ComposeInput.maximumIncludeDepth) files deep"
            ])
    }

    /// The app loads a project off the main thread, where the stack is small: 512 nested
    /// includes overran it and took the process down.
    @Test
    func aVeryDeepChainIsRefusedOnAWorkerInsteadOfOverrunningItsStack() async throws {
        let project = try chain(512)
        let failure = await Task.detached { loadFailure { try project.load() } }.value
        #expect(failure.count == 1)
        #expect(failure.first?.hasSuffix("include is nested more than \(ComposeInput.maximumIncludeDepth) files deep") == true)
    }

    /// Two references to the next file at each level: 493 bytes that asked for 131,071 reads.
    @Test(.timeLimit(.minutes(1)))
    func aFileIncludedOverAndOverMeetsTheFileBudgetQuickly() async throws {
        let project = try chain(17, references: 2)
        let clock = ContinuousClock()
        var failure: [String] = []
        let elapsed = clock.measure { failure = loadFailure { try project.load() } }
        #expect(failure.count == 1)
        #expect(failure.first?.hasSuffix("the project includes more than \(ComposeInput.maximumIncludedFiles) files") == true)
        #expect(elapsed < .seconds(5))
    }

    @Test
    func aFileIncludedTwiceWithinTheBudgetIsReadBothTimes() throws {
        let project = try chain(5, references: 2)
        let definition = try project.load()
        #expect(definition.file.services.count == 6)
        #expect(definition.includedFiles.count == 5, "each file is listed once however often it is read")
    }

    @Test
    func includedFilesTogetherStayWithinTheInputBudget() throws {
        // Comments: read and parsed, and no part of what the interpolation budget counts.
        let filler = "# " + String(repeating: "a", count: 1_000_000) + "\n"
        var files = ["compose.yaml": "include: [" + (1...9).map { "big\($0).yaml" }.joined(separator: ", ") + "]\nservices:\n  a: {image: a}\n"]
        for index in 1...9 { files["big\(index).yaml"] = filler + "services:\n  b\(index): {image: b}\n" }
        let project = try TemporaryProject(files, named: "big")
        let failure = loadFailure { try project.load() }
        #expect(failure.count == 1)
        #expect(failure.first?.hasSuffix("include: the included files exceed the 8 MiB compose input budget") == true, "\(failure)")
    }
}
