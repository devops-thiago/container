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

/// A project directory made for one test and removed after it.
final class TemporaryProject {
    let directory: URL

    init(_ files: [String: String] = [:], named name: String = "project") throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-tests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, text) in files {
            try write(text, to: path)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    func write(_ text: String, to path: String) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    /// The path as the file system reports it: `/var` is `/private/var` once resolved.
    var path: String { directory.resolvingSymlinksInPath().path }

    func load(
        files: [String] = [],
        name: String? = nil,
        profiles: [String]? = nil,
        envFiles: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        projectDirectory: String? = nil,
        searchesParents: Bool = false
    ) throws -> ComposeDefinition {
        try ComposeLoader.load(
            ComposeLoader.Options(
                files: files,
                workingDirectory: workingDirectory ?? path,
                projectDirectory: projectDirectory,
                projectName: name,
                profiles: profiles,
                envFiles: envFiles,
                environment: environment,
                homeDirectory: "/Users/tester",
                searchesParents: searchesParents))
    }
}

enum Fixture {
    /// A directory under `Fixtures`, as the test bundle carries it.
    static func directory(_ name: String) throws -> String {
        let fixtures = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures", isDirectory: true)
        return fixtures.appendingPathComponent(name, isDirectory: true).resolvingSymlinksInPath().path
    }

    static func load(
        _ name: String, files: [String] = [], profiles: [String]? = nil, environment: [String: String] = [:]
    ) throws -> ComposeDefinition {
        try ComposeLoader.load(
            ComposeLoader.Options(
                files: files,
                workingDirectory: try directory(name),
                profiles: profiles,
                environment: environment,
                homeDirectory: "/Users/tester",
                searchesParents: false))
    }
}

/// The messages of the error a load throws, for tests about what is refused.
func loadFailure(_ body: () throws -> ComposeDefinition) -> [String] {
    do {
        _ = try body()
        return []
    } catch let error as ComposeError {
        return error.diagnostics.map(\.description)
    } catch {
        return ["\(error)"]
    }
}

/// A project of one service with these settings, loaded.
func loadService(_ settings: String, extra: String = "", environment: [String: String] = [:]) throws -> ComposeService {
    let indented = settings.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
    let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n\(indented)\n\(extra)"])
    return try #require(try project.load(environment: environment).file.service("web"))
}

/// What a project of one service with these settings is refused or warned for.
func diagnose(_ settings: String, extra: String = "") throws -> (errors: [String], warnings: [String]) {
    let indented = settings.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
    let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n\(indented)\n\(extra)"])
    do {
        let definition = try project.load()
        return ([], definition.warnings.map(\.description))
    } catch let error as ComposeError {
        return (error.diagnostics.map(\.description), [])
    }
}
