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

/// Env files: what an include may read of them, and a file the system keeps closed, which
/// is neither a missing file nor one to leave out.
struct EnvFileAccessTests {
    private func refusal(_ body: () throws -> ComposeDefinition) -> ComposeError? {
        do {
            _ = try body()
            return nil
        } catch let error as ComposeError {
            return error
        } catch {
            Issue.record("\(error)")
            return nil
        }
    }

    /// A folder closed to this process for as long as `body` runs.
    private func closed<T>(_ path: String, permissions: Int = 0o000, _ body: () throws -> T) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let before = try #require(attributes[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: before], ofItemAtPath: path) }
        return try body()
    }

    private func including(_ count: Int, of file: String) -> String {
        "include:\n  - path: inc/compose.yaml\n    env_file: [" + Array(repeating: file, count: count).joined(separator: ", ")
            + "]\nservices:\n  a: {image: a}\n"
    }

    // MARK: What an include reads

    /// One compose file and the same 100 KB env file named 300 times: 30 MB that was read
    /// and parsed outside the 8 MiB the includes of a project may come to.
    @Test(.timeLimit(.minutes(1)))
    func envFilesAnIncludeNamesCountAgainstTheByteBudget() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": including(300, of: "big.env"),
                "inc/compose.yaml": "services:\n  db: {image: one}\n",
                "big.env": "# " + String(repeating: "a", count: 100_000) + "\nA=1\n",
            ], named: "shop")
        let clock = ContinuousClock()
        var failure: [String] = []
        let elapsed = clock.measure { failure = loadFailure { try project.load() } }
        #expect(failure == ["compose.yaml:2:5: include: the included files exceed the 8 MiB compose input budget"])
        #expect(elapsed < .seconds(5))
    }

    @Test
    func envFilesAnIncludeNamesCountAgainstTheFileBudget() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": including(ComposeInput.maximumIncludedFiles, of: "small.env"),
                "inc/compose.yaml": "services:\n  db: {image: one}\n",
                "small.env": "A=1\n",
            ], named: "shop")
        // The compose file is one read, so the last env file is one too many.
        #expect(
            loadFailure { try project.load() } == [
                "compose.yaml:2:5: include: the project includes more than \(ComposeInput.maximumIncludedFiles) files"
            ])
        try project.write(including(ComposeInput.maximumIncludedFiles - 1, of: "small.env"), to: "compose.yaml")
        #expect(try project.load().file.services.map(\.name) == ["a", "db"])
    }

    /// The `.env` an included project has without naming it is a file read as well.
    @Test
    func anIncludedProjectsOwnEnvFileCountsToo() throws {
        let filler = "# " + String(repeating: "a", count: 1_000_000) + "\n"
        var files = ["compose.yaml": "include: [" + (1...9).map { "p\($0)/compose.yaml" }.joined(separator: ", ") + "]\nservices:\n  a: {image: a}\n"]
        for index in 1...9 {
            files["p\(index)/compose.yaml"] = "services:\n  b\(index): {image: b}\n"
            files["p\(index)/.env"] = filler
        }
        let project = try TemporaryProject(files, named: "shop")
        let failure = loadFailure { try project.load() }
        #expect(failure.count == 1)
        #expect(failure.first?.hasSuffix("include: the included files exceed the 8 MiB compose input budget") == true, "\(failure)")
    }

    @Test
    func envFilesWithinTheBudgetKeepTheirValuesAndTheirOrder() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                include:
                  - path: inc/compose.yaml
                    env_file: [one.env, two.env, one.env, two.env]
                services:
                  a: {image: a}
                """,
                "inc/compose.yaml": "services:\n  db:\n    image: \"img:${V}-${ONLY}-${P}\"\n",
                "one.env": "V=one\nONLY=first\nP=included\n",
                "two.env": "V=two\n",
                ".env": "P=parent\n",
            ], named: "shop")
        let definition = try project.load()
        let db = try #require(definition.file.services.first { $0.name == "db" })
        #expect(db.image == "img:two-first-parent", "a later file wins, and the including project over both")
    }

    // MARK: A file the system keeps closed

    /// The root in one folder, the service it includes in a second, and that service's env
    /// file in a third this process may not look into.
    private func threeFolders(required: Bool) throws -> TemporaryProject {
        try TemporaryProject(
            [
                "a/compose.yaml": "include: [../b/compose.yaml]\nservices:\n  app: {image: a}\n",
                "b/compose.yaml": """
                services:
                  db:
                    image: one
                    env_file:
                      - path: ../c/db.env
                        required: \(required)
                """,
                "c/db.env": "A=1\n",
            ], named: "shop")
    }

    @Test(arguments: [true, false])
    func aServiceEnvFileInAClosedFolderIsNamedRequiredOrNot(required: Bool) throws {
        let project = try threeFolders(required: required)
        let file = "\(project.path)/c/db.env"
        let open = try project.load(workingDirectory: "\(project.path)/a")
        #expect(open.file.services.first { $0.name == "db" }?.environment == ["A": "1"])

        let error = try closed("\(project.path)/c") { refusal { try project.load(workingDirectory: "\(project.path)/a") } }
        #expect(error?.deniedPath == file)
        #expect(error?.diagnostics.map(\.description) == ["\(project.path)/b/compose.yaml:5:9: services.db.env_file: \(file) could not be read: Permission denied"])
    }

    @Test(arguments: [true, false])
    func aServiceEnvFileThatCannotBeOpenedIsNamedRequiredOrNot(required: Bool) throws {
        let project = try threeFolders(required: required)
        let file = "\(project.path)/c/db.env"
        let error = try closed(file) { refusal { try project.load(workingDirectory: "\(project.path)/a") } }
        #expect(error?.deniedPath == file)
        #expect(error?.diagnostics.count == 1)
        #expect(error?.diagnostics.first?.message.hasPrefix("\(file) could not be read: ") == true)
    }

    @Test
    func aServiceEnvFileThatIsNotThereIsNotOneToAskFor() throws {
        let required = try threeFolders(required: true)
        try FileManager.default.removeItem(atPath: "\(required.path)/c/db.env")
        let error = refusal { try required.load(workingDirectory: "\(required.path)/a") }
        #expect(error?.deniedPath == nil)
        #expect(error?.diagnostics.map(\.message) == ["\(required.path)/c/db.env does not exist"])

        let optional = try threeFolders(required: false)
        try FileManager.default.removeItem(atPath: "\(optional.path)/c/db.env")
        let definition = try optional.load(workingDirectory: "\(optional.path)/a")
        #expect(definition.file.services.first { $0.name == "db" }?.environment == [:])
    }

    /// Without an include: the service is the project's own.
    @Test
    func aProjectsOwnServiceEnvFileInAClosedFolderIsNamed() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "services:\n  db:\n    image: one\n    env_file: [closed/db.env, other/more.env]\n",
                "closed/db.env": "A=1\n",
                "other/more.env": "B=2\n",
            ], named: "shop")
        let error = try closed("\(project.path)/closed") {
            try closed("\(project.path)/other") { refusal { try project.load() } }
        }
        #expect(error?.diagnostics.count == 2)
        #expect(error?.deniedPath == "\(project.path)/closed/db.env", "the first one, for an embedder that asks for one folder at a time")
    }

    /// A service whose profile is off does not run, and nothing is asked for on its account.
    @Test
    func aClosedEnvFileOfAServiceThatDoesNotRunStopsNothing() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                services:
                  app: {image: a}
                  db:
                    image: one
                    profiles: [data]
                    env_file: [closed/db.env]
                """,
                "closed/db.env": "A=1\n",
            ], named: "shop")
        try closed("\(project.path)/closed") {
            let definition = try project.load()
            #expect(definition.withheld[.service("db")]?.map(\.message) == ["\(project.path)/closed/db.env could not be read: Permission denied"])
            let error = refusal { try project.load(profiles: ["data"]) }
            #expect(error?.deniedPath == "\(project.path)/closed/db.env")
        }
    }

    @Test
    func aProjectEnvFileInAClosedFolderIsNamedAndNotLeftOut() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "services:\n  a: {image: \"img:${V:-unset}\"}\n",
                "vars/.env": "V=set\n",
                "vars/named.env": "V=named\n",
            ], named: "shop")
        try closed("\(project.path)/vars") {
            // The `.env` nothing names, where the project directory is.
            let unnamed = refusal { try project.load(files: ["compose.yaml"], projectDirectory: "\(project.path)/vars") }
            #expect(unnamed?.deniedPath == "\(project.path)/vars/.env")
            let named = refusal { try project.load(envFiles: ["vars/named.env"]) }
            #expect(named?.deniedPath == "\(project.path)/vars/named.env")
            #expect(named?.diagnostics.map(\.message) == ["\(project.path)/vars/named.env could not be read: Permission denied"])
        }
    }

    /// The control: an include's own env file already said so.
    @Test
    func anIncludesEnvFileInAClosedFolderIsNamed() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "include:\n  - path: inc/compose.yaml\n    env_file: [closed/inc.env]\nservices:\n  a: {image: a}\n",
                "inc/compose.yaml": "services:\n  db: {image: one}\n",
                "closed/inc.env": "A=1\n",
            ], named: "shop")
        let error = try closed("\(project.path)/closed") { refusal { try project.load() } }
        #expect(error?.deniedPath == "\(project.path)/closed/inc.env")
    }
}
