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

/// A compose project read from its files: what `up` would run, before anything is run.
public struct ComposeDefinition: Sendable, Equatable {
    /// The project name: what its containers, networks and volumes are named after.
    public let name: String
    /// The directory relative paths in the files are relative to.
    public let directory: String
    /// The files the project was read from, in the order they were merged.
    public let configFiles: [String]
    /// The files `include` brought in, in the order they were read. They are not among
    /// `configFiles`, as `docker compose` leaves them out of the project's config files.
    public let includedFiles: [String]
    public let file: ComposeFile
    /// The profiles asked for. `*` turns every profile on.
    public let profiles: [String]
    /// What the files say that will not happen, or not as written.
    public let warnings: [ComposeDiagnostic]
    /// What was found about the parts of the project that do not run as it was read: a
    /// service whose profiles are off, and a network or a volume that no service which runs
    /// uses. Errors and warnings both. They count once the part is planned, which naming
    /// the service does.
    public let withheld: [ComposePart: [ComposeDiagnostic]]

    public init(
        name: String, directory: String, configFiles: [String], includedFiles: [String] = [], file: ComposeFile, profiles: [String],
        warnings: [ComposeDiagnostic], withheld: [ComposePart: [ComposeDiagnostic]] = [:]
    ) {
        self.name = name
        self.directory = directory
        self.configFiles = configFiles
        self.includedFiles = includedFiles
        self.file = file
        self.profiles = profiles
        self.warnings = warnings
        self.withheld = withheld
    }

    /// The parts held back with something wrong with them, and what is wrong, in the order
    /// the files have it. Such a part was not read as the files mean it, so it is not what
    /// `file` says of it either.
    public var unread: [(part: ComposePart, errors: [ComposeDiagnostic])] {
        let found = withheld.compactMap { part, diagnostics -> (part: ComposePart, errors: [ComposeDiagnostic])? in
            let errors = diagnostics.filter { $0.severity == .error }
            return errors.isEmpty ? nil : (part, errors)
        }
        let order = DiagnosticCollector.inFileOrder(found.compactMap(\.errors.first))
        return found.sorted { first, second in
            (order.firstIndex(of: first.errors[0]) ?? 0) < (order.firstIndex(of: second.errors[0]) ?? 0)
        }
    }
}

/// Reads compose files the way `docker compose` does: finds them, substitutes variables,
/// merges them in order, and checks the result against what this engine can run.
public enum ComposeLoader {
    public struct Options: Sendable {
        /// The files named with `-f`, in order. Empty looks for one where compose was run.
        public var files: [String]
        /// Where compose was run: what a relative `-f` is relative to, and where the search
        /// for a compose file starts.
        public var workingDirectory: String
        /// `--project-directory`: what relative paths inside the files are relative to.
        /// nil is the directory of the first compose file.
        public var projectDirectory: String?
        /// `-p`. nil takes `COMPOSE_PROJECT_NAME`, the files' `name:`, then the directory.
        public var projectName: String?
        /// `--profile`. nil takes `COMPOSE_PROFILES`. Given, they are the whole set and the
        /// variable is not read, as with `docker compose`; an empty list turns every profile
        /// off, whatever a `.env` says.
        public var profiles: [String]?
        /// `--env-file`. Empty reads `.env` in the project directory when there is one.
        public var envFiles: [String]
        /// The environment compose runs in. It wins over the env files.
        public var environment: [String: String]
        /// What `~` means at the start of a path.
        public var homeDirectory: String
        /// Whether a search with no `-f` goes up through the parent directories.
        public var searchesParents: Bool

        public init(
            files: [String] = [],
            workingDirectory: String,
            projectDirectory: String? = nil,
            projectName: String? = nil,
            profiles: [String]? = nil,
            envFiles: [String] = [],
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: String = ComposeLoader.userHomeDirectory(),
            searchesParents: Bool = true
        ) {
            self.files = files
            self.workingDirectory = workingDirectory
            self.projectDirectory = projectDirectory
            self.projectName = projectName
            self.profiles = profiles
            self.envFiles = envFiles
            self.environment = environment
            self.homeDirectory = homeDirectory
            self.searchesParents = searchesParents
        }
    }

    /// The file names looked for when none is given, best first.
    public static let defaultFileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    /// The override files merged over the one found, when one of them sits beside it.
    public static let overrideFileNames = [
        "compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml",
    ]

    /// The user's home directory as the account database has it. A sandboxed process's
    /// `HOME` is its container, which is not what `~` in a compose file means.
    public static func userHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }

    /// The name the project goes by, without reading the files any further than it takes to
    /// find one. Commands that work on what already runs need no more than this, and should
    /// not fail on a file that no longer describes it.
    public static func projectName(_ options: Options) throws -> String {
        try sources(options).name
    }

    /// What reading starts from: which files, where relative paths lead, the variables in
    /// play, and the project's name.
    private struct Sources {
        let working: URL
        let files: [URL]
        let directory: URL
        var variables: [String: String]
        let documents: [ComposeNode]
        let name: String
    }

    private static func sources(_ options: Options) throws -> Sources {
        let working = URL(fileURLWithPath: options.workingDirectory, isDirectory: true).standardizedFileURL
        let files = try configFiles(options, working: working)
        let directory = options.projectDirectory.map { resolve($0, against: working) } ?? files[0].deletingLastPathComponent()

        // Variables: the env files, with the environment compose runs in on top.
        var variables: [String: String] = [:]
        let explicit = options.envFiles.map { resolve($0, against: working).path }
        let defaultFile = directory.appendingPathComponent(".env").path
        for path in explicit.isEmpty ? [defaultFile] : explicit {
            switch presence(of: path) {
            case .present:
                break
            case .absent:
                guard explicit.isEmpty else { throw ComposeError("the env file \(path) does not exist") }
                continue
            case .denied(let reason):
                var denied = ComposeError("\(path) could not be read: \(reason)")
                denied.deniedPath = path
                throw denied
            }
            let text = try readText(path)
            let known = variables
            for entry in try DotEnv.parse(text, file: path, lookup: { options.environment[$0] ?? known[$0] }) {
                if let value = entry.value { variables[entry.key] = value }
            }
        }
        variables.merge(options.environment) { _, fromEnvironment in fromEnvironment }

        let documents = try files.map { try ComposeNode.parse(yaml: try readText($0.path), file: displayName($0, relativeTo: working)) }

        // The name is needed before the files are read in full, because they may use it.
        let name = try projectName(options, documents: documents, variables: variables, directory: directory)
        if variables["COMPOSE_PROJECT_NAME"] == nil { variables["COMPOSE_PROJECT_NAME"] = name }
        return Sources(working: working, files: files, directory: directory, variables: variables, documents: documents, name: name)
    }

    /// Read the project. Throws `ComposeError` with everything that keeps it from running.
    ///
    /// A service whose profiles are off does not run, and neither does a network or a volume
    /// that only such services use, so what is wrong with one of those does not stop the
    /// project: it is kept in `ComposeDefinition.withheld` for a plan that uses the part.
    public static func load(_ options: Options) throws -> ComposeDefinition {
        let sources = try sources(options)
        let (files, directory, variables, documents, name) = (sources.files, sources.directory, sources.variables, sources.documents, sources.name)

        let diagnostics = DiagnosticCollector()
        let context = DecodeContext(projectDirectory: directory, homeDirectory: options.homeDirectory, diagnostics: diagnostics)

        let reading = Reading(context: context, working: sources.working, chain: files.map(\.path))
        let merged = try model(documents, variables: variables, in: reading)
        for variable in reading.state.unset {
            diagnostics.warn("", "the variable \(variable) is not set; it reads as an empty string")
        }

        try Task.checkCancellation()
        let file = Resolver(context: context, environment: variables).resolve(merged)
        try Task.checkCancellation()

        let fromEnvironment = (variables["COMPOSE_PROFILES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var profiles: [String] = []
        // The ones asked for replace the variable's; they are not added to it. Added, a
        // profile a `.env` turns on could not be turned off by naming the ones wanted.
        for profile in options.profiles ?? fromEnvironment where !profile.isEmpty && !profiles.contains(profile) {
            profiles.append(profile)
        }

        let used = file.parts(of: file.services.filter { $0.isActive(in: profiles) })
        let withheld = diagnostics.withhold { !used.contains($0) }
        do {
            try diagnostics.throwIfFailed()
        } catch var error as ComposeError {
            // Whoever shows the refusal can offer the profile that brought a refused service
            // in, as a refusal from planning does.
            error.namedProfiles = Set(file.services.flatMap(\.profiles)).sorted()
            error.activeProfiles = profiles
            throw error
        }
        return ComposeDefinition(
            name: name,
            directory: directory.path,
            configFiles: files.map(\.path),
            includedFiles: reading.state.included,
            file: file,
            profiles: profiles,
            warnings: DiagnosticCollector.inFileOrder(diagnostics.warnings),
            withheld: withheld)
    }

    // MARK: Files

    /// `path` as an absolute location: itself when it is one, under `directory` otherwise.
    static func resolve(_ path: String, against directory: URL) -> URL {
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path).standardizedFileURL }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    static func readText(_ path: String) throws -> String {
        do {
            return try ComposeInput.read(path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var failure = ComposeError("\(path) could not be read: \(error.localizedDescription)")
            if isDenial(error) { failure.deniedPath = path }
            throw failure
        }
    }

    /// Whether there is a file at a path, as far as this process may know.
    enum Presence: Equatable {
        case present
        case absent
        /// The system would not say: the file, or a folder on the way to it, is closed to
        /// this process. With the system's reason.
        case denied(String)
    }

    /// A file that may not be looked at is not an absent one. Read as absent, an env file
    /// would be left out without a word and the project would run with other values, and
    /// an embedder that could ask for the file's folder would not know to.
    static func presence(of path: String) -> Presence {
        var status = stat()
        guard stat(path, &status) != 0 else { return .present }
        let code = errno
        guard code == EACCES || code == EPERM else { return .absent }
        return .denied(String(cString: strerror(code)))
    }

    /// Whether a read failed because the system would not let this process open the file,
    /// and not because of what the file is.
    static func isDenial(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isDenial(underlying)
    }

    /// The path to show in messages: as short as the user would have typed it.
    static func displayName(_ file: URL, relativeTo working: URL) -> String {
        let directory = working.path.hasSuffix("/") ? working.path : working.path + "/"
        return file.path.hasPrefix(directory) ? String(file.path.dropFirst(directory.count)) : file.path
    }

    /// The compose files to read: the ones named, the ones `COMPOSE_FILE` names, or the
    /// one found in the working directory or above it, with its override beside it.
    static func configFiles(_ options: Options, working: URL) throws -> [URL] {
        var named = options.files
        if named.isEmpty, let fromEnvironment = options.environment["COMPOSE_FILE"], !fromEnvironment.isEmpty {
            let separator = options.environment["COMPOSE_PATH_SEPARATOR"].flatMap(\.first) ?? ":"
            named = fromEnvironment.split(separator: separator).map(String.init)
        }
        if !named.isEmpty {
            let files = named.map { resolve($0, against: working) }
            for file in files where !FileManager.default.fileExists(atPath: file.path) {
                throw ComposeError("the compose file \(file.path) does not exist")
            }
            return files
        }

        var directory = options.projectDirectory.map { resolve($0, against: working) } ?? working
        while true {
            if let found = defaultFileNames.map({ directory.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let override = overrideFileNames.map { directory.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                return [found] + (override.map { [$0] } ?? [])
            }
            let parent = directory.deletingLastPathComponent()
            guard options.searchesParents, parent.path != directory.path else { break }
            directory = parent
        }
        throw ComposeError(
            "no compose file found in \(working.path)\(options.searchesParents ? " or the directories above it" : ""): looked for \(defaultFileNames.joined(separator: ", ")). Name one with -f"
        )
    }

    // MARK: Name

    static func projectName(
        _ options: Options, documents: [ComposeNode], variables: [String: String], directory: URL
    ) throws -> String {
        if let explicit = options.projectName ?? variables["COMPOSE_PROJECT_NAME"], !explicit.isEmpty {
            guard nameValid(explicit) else {
                throw ComposeError("'\(explicit)' is not a project name: lowercase letters, digits, '-' and '_', starting with a letter or digit")
            }
            return explicit
        }
        var interpolator = Interpolator(lookup: { variables[$0] })
        interpolator.strict = false
        // The last file to give a name wins, as with every other single value.
        for document in documents.reversed() {
            guard let node = document["name"], let written = node.scalar else { continue }
            let name = (try? interpolator.interpolate(written)) ?? written
            guard nameValid(name) else {
                throw ComposeError(
                    path: "name", "'\(name)' is not a project name: lowercase letters, digits, '-' and '_', starting with a letter or digit",
                    at: node.location)
            }
            return name
        }
        let normalized = normalize(directory.lastPathComponent)
        guard nameValid(normalized) else {
            throw ComposeError("the directory name '\(directory.lastPathComponent)' cannot be made into a project name; give one with -p")
        }
        return normalized
    }

    /// A project name, as compose defines one.
    public static func nameValid(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { $0 == "-" || $0 == "_" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) }
    }

    /// A directory name made into a project name: lowercased, with what a name cannot hold
    /// dropped, and nothing but a letter or digit in front.
    static func normalize(_ name: String) -> String {
        let kept = name.lowercased().filter { $0 == "-" || $0 == "_" || ($0.isASCII && ($0.isLowercase || $0.isNumber)) }
        return String(kept.drop { $0 == "-" || $0 == "_" })
    }
}
