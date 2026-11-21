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

// `include`: other compose files read as projects of their own, each with its own directory
// and variables, and merged under the file that names them.
//
// Measured against Docker Compose 5.6.1 (`docker compose config`), which is what this
// follows where the specification leaves a case open:
// - a relative `path`, `project_directory` or `env_file` is relative to the including
//   project's directory, not to the file that has the `include`;
// - what the including files say of a service, network or volume merges over what an
//   included file says of it, and an earlier include merges over a later one;
// - the including project's variables win over the included project's env file;
// - an included file's `name` is not the project's.

extension ComposeLoader {
    /// What is shared by every file of one load, however deep the file is included.
    final class ReadingState {
        /// Variables a file uses that nothing sets, in the order they were met.
        var unset: [String] = []
        var expandedBytes = 0
        /// The files brought in by `include`, in the order they were read.
        var included: [String] = []
    }

    /// Where one project's files are read: the including project, or an included one.
    struct Reading {
        var context: DecodeContext
        /// Where compose was run, which file names in messages are shortened against.
        let working: URL
        /// The files being read, outermost first. Including one of them again is a cycle.
        var chain: [String]
        /// Whether this is an included project, whose services keep its own variables.
        var isIncluded = false
        let state = ReadingState()
    }

    /// One entry of an `include` list.
    struct Include {
        var paths: [String]
        var projectDirectory: String?
        /// nil reads `.env` in the project directory when there is one.
        var envFiles: [String]?
        var location: SourceLocation
    }

    /// The project `documents` come to, with what they include merged under them.
    static func model(_ documents: [ComposeNode], variables: [String: String], in reading: Reading) throws -> RawProject {
        let diagnostics = reading.context.diagnostics
        let state = reading.state
        var interpolator = Interpolator(lookup: { variables[$0] })
        interpolator.onUnset = { name in
            if !state.unset.contains(name) { state.unset.append(name) }
        }
        var merged = RawProject()
        var includes: [Include] = []
        for document in documents {
            let substituted = try document.mapScalars { text, node in
                try Task.checkCancellation()
                do {
                    let value = try interpolator.interpolate(text)
                    state.expandedBytes += value.utf8.count
                    guard state.expandedBytes <= ComposeInput.maximumExpandedBytes else {
                        throw ComposeError("interpolated project exceeds the 8 MiB compose input budget", at: node.location)
                    }
                    return value
                } catch let error as ComposeError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diagnostics.error("", "\(error)", at: node.location)
                    return text
                }
            }
            var project = reading.context.project(substituted)
            if reading.isIncluded {
                project.keep(variables: variables, directory: reading.context.projectDirectory)
            }
            merged = merged.merging(project)
            includes += try self.includes(of: substituted, context: reading.context)
        }
        // After the files themselves, as `docker compose` does: each include goes under
        // everything read so far, so the first one named is the one that wins.
        for include in includes {
            try Task.checkCancellation()
            merged = try model(of: include, variables: variables, in: reading).merging(merged)
        }
        return merged
    }

    /// The entries of a file's `include`, with what is wrong with one reported and the entry
    /// left out.
    static func includes(of document: ComposeNode, context: DecodeContext) throws -> [Include] {
        guard let node = document["include"] else { return [] }
        let items: [ComposeNode]
        switch node.value {
        case .null:
            return []
        case .sequence(let sequence):
            items = sequence
        default:
            throw ComposeError(path: "include", "expected a list, found \(node.kind)", at: node.location)
        }
        var includes: [Include] = []
        for (index, item) in items.enumerated() {
            let path = "include[\(index)]"
            if case .scalar(let file) = item.value {
                includes.append(Include(paths: [file], location: item.location))
                continue
            }
            // Attributes other than these three pass unread, as they do with `docker compose`.
            guard var reader = MappingReader(item, path: path, diagnostics: context.diagnostics) else { continue }
            guard let paths = reader.value("path", { context.texts($0, $1) }), !paths.isEmpty else {
                context.diagnostics.error("\(path).path", "an include names the file to read", at: item.location)
                continue
            }
            includes.append(
                Include(
                    paths: paths,
                    projectDirectory: reader.value("project_directory", context.text),
                    envFiles: reader.value("env_file", { context.texts($0, $1) }),
                    location: item.location))
        }
        return includes
    }

    /// The project one include brings in: its files merged, read in its own directory with
    /// its own variables under the including project's.
    private static func model(of include: Include, variables: [String: String], in reading: Reading) throws -> RawProject {
        let base = reading.context.projectDirectory
        for path in include.paths where path.contains("://") {
            throw ComposeError(path: "include", "\(path): a compose file fetched from a registry or a repository cannot be included", at: include.location)
        }
        let files = include.paths.map { resolve($0, against: base) }
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ComposeError(path: "include", "the included file \(file.path) does not exist", at: include.location)
            }
            if reading.chain.contains(file.path) {
                let cycle = (reading.chain + [file.path]).map { displayName(URL(fileURLWithPath: $0), relativeTo: reading.working) }
                throw ComposeError(path: "include", "the files include each other: \(cycle.joined(separator: " includes "))", at: include.location)
            }
        }
        let directory = include.projectDirectory.map { resolve($0, against: base) } ?? files[0].deletingLastPathComponent()

        var own: [String: String] = [:]
        let named = include.envFiles?.map { resolve($0, against: base).path }
        for path in named ?? [directory.appendingPathComponent(".env").path] {
            guard FileManager.default.fileExists(atPath: path) else {
                guard named == nil else {
                    throw ComposeError(path: "include", "the env file \(path) does not exist", at: include.location)
                }
                continue
            }
            let known = own
            for entry in try DotEnv.parse(try readText(path), file: path, lookup: { variables[$0] ?? known[$0] }) {
                if let value = entry.value { own[entry.key] = value }
            }
        }
        own.merge(variables) { _, including in including }

        let documents = try files.map { try ComposeNode.parse(yaml: try readText($0.path), file: displayName($0, relativeTo: reading.working)) }
        for file in files where !reading.state.included.contains(file.path) {
            reading.state.included.append(file.path)
        }
        var inner = reading
        inner.context = DecodeContext(
            projectDirectory: directory, homeDirectory: reading.context.homeDirectory, diagnostics: reading.context.diagnostics)
        inner.chain += files.map(\.path)
        inner.isIncluded = true
        return try model(documents, variables: own, in: inner)
    }
}

extension RawProject {
    /// Settle what an included file leaves to its project, before it merges into another:
    /// a name without a value takes the included project's, a build with no context builds
    /// that project's directory, and an env file is read with that project's variables.
    /// The file's `name` names nothing: the project is the including one.
    mutating func keep(variables: [String: String], directory: URL) {
        name = nil
        for key in services.keys {
            services[key]?.keep(variables: variables, directory: directory)
        }
    }
}

extension RawService {
    fileprivate mutating func keep(variables: [String: String], directory: URL) {
        func settled(_ pairs: [String: String?]?) -> [String: String?]? {
            guard let pairs else { return nil }
            var result: [String: String?] = [:]
            for (key, value) in pairs { result.updateValue(value ?? variables[key], forKey: key) }
            return result
        }
        environment = settled(environment)
        if var declared = build {
            declared.context = declared.context ?? directory.standardizedFileURL.path
            declared.args = settled(declared.args)
            build = declared
        }
        envFiles = envFiles?.map { file in
            var file = file
            file.scope = file.scope ?? variables
            return file
        }
    }
}
