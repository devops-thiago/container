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

/// Where a value sits in a compose file.
public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
    /// The file as the user named it, or as discovery found it.
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String { "\(file):\(line):\(column)" }
}

/// Something a compose file says that the person running it should hear about.
public struct ComposeDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        /// The project runs; this part of the file does nothing, or less than it asks.
        case warning
        /// The project cannot run as written.
        case error
    }

    public let severity: Severity
    /// The key the message is about, as a path: `services.web.privileged`.
    public let path: String
    public let message: String
    public let location: SourceLocation?

    public init(severity: Severity, path: String, message: String, location: SourceLocation? = nil) {
        self.severity = severity
        self.path = path
        self.message = message
        self.location = location
    }

    public var description: String {
        let subject = path.isEmpty ? message : "\(path): \(message)"
        guard let location else { return subject }
        return "\(location): \(subject)"
    }
}

extension ComposeDiagnostic {
    /// The diagnostics as lines for a person to read, with the ones that say the same
    /// thing about the same setting of several services said once: five services with a
    /// `logging` key are one line that names the five.
    public static func lines(_ diagnostics: [ComposeDiagnostic]) -> [String] {
        // A service's setting is `services.<name>.<setting>`; what follows the name is
        // what several services can share.
        func setting(_ diagnostic: ComposeDiagnostic) -> (service: String, rest: String)? {
            let parts = diagnostic.path.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "services" else { return nil }
            return (String(parts[1]), String(parts[2]))
        }
        var lines: [String] = []
        var grouped: [String: Int] = [:]
        var services: [[String]] = []
        for diagnostic in diagnostics {
            guard let setting = setting(diagnostic) else {
                lines.append(diagnostic.description)
                services.append([])
                continue
            }
            let key = "\(setting.rest)\u{0}\(diagnostic.message)"
            if let index = grouped[key] {
                if !services[index].contains(setting.service) { services[index].append(setting.service) }
                lines[index] = "services.{\(services[index].joined(separator: ","))}.\(setting.rest): \(diagnostic.message)"
            } else {
                grouped[key] = lines.count
                lines.append(diagnostic.description)
                services.append([setting.service])
            }
        }
        return lines
    }
}

/// A part of a project that is made only when something that runs uses it: a service, and
/// the networks and volumes services name.
public enum ComposePart: Sendable, Hashable, CustomStringConvertible {
    case service(String)
    /// By the key the files know the network by.
    case network(String)
    /// By the key the files know the volume by.
    case volume(String)

    /// The part as a path in the files: `services.web`.
    public var description: String {
        switch self {
        case .service(let name): "services.\(name)"
        case .network(let key): "networks.\(key)"
        case .volume(let key): "volumes.\(key)"
        }
    }

    /// Why the part is not in a project written out from what was read, for one that was
    /// held back with something wrong with it.
    public var leftOut: String {
        switch self {
        case .service: "\(self) is left out: its profile is off, and it cannot run as written"
        case .network, .volume: "\(self) is left out: no service that runs uses it, and it cannot be made as written"
        }
    }
}

/// A compose file, or a set of them, that cannot be run as written. Carries every reason
/// found, not the first: a file with three unsupported keys says so once.
public struct ComposeError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let diagnostics: [ComposeDiagnostic]

    public init(_ diagnostics: [ComposeDiagnostic]) {
        self.diagnostics = diagnostics
    }

    public init(path: String = "", _ message: String, at location: SourceLocation? = nil) {
        self.diagnostics = [ComposeDiagnostic(severity: .error, path: path, message: message, location: location)]
    }

    public var description: String {
        diagnostics.map(\.description).joined(separator: "\n")
    }

    public var errorDescription: String? { description }
}

/// Collects what loading finds, so one pass over the files reports everything.
final class DiagnosticCollector {
    private(set) var warnings: [ComposeDiagnostic] = []
    private(set) var errors: [ComposeDiagnostic] = []
    /// The part being read, when one is.
    private var part: ComposePart?
    /// The part each diagnostic is about, for the ones that are about one.
    private var parts: [ComposeDiagnostic: ComposePart] = [:]

    func warn(_ path: String, _ message: String, at location: SourceLocation? = nil) {
        add(ComposeDiagnostic(severity: .warning, path: path, message: message, location: location))
    }

    func error(_ path: String, _ message: String, at location: SourceLocation? = nil) {
        add(ComposeDiagnostic(severity: .error, path: path, message: message, location: location))
    }

    /// Take a diagnostic as it is: one found earlier, about something that is used after all.
    func add(_ diagnostic: ComposeDiagnostic) {
        switch diagnostic.severity {
        case .warning:
            guard !warnings.contains(diagnostic) else { return }
            warnings.append(diagnostic)
        case .error:
            guard !errors.contains(diagnostic) else { return }
            errors.append(diagnostic)
        }
        if let part { parts[diagnostic] = part }
    }

    /// Run `body` with what it reports marked as being about `part`.
    func reading<T>(_ part: ComposePart, _ body: () -> T) -> T {
        let outer = self.part
        self.part = part
        defer { self.part = outer }
        return body()
    }

    /// Take out what was found about the parts `unused` says nothing uses, and return it by
    /// part, in the order someone reading the files meets it. What is left is about the
    /// project, or about a part of it that runs.
    func withhold(where unused: (ComposePart) -> Bool) -> [ComposePart: [ComposeDiagnostic]] {
        var withheld: [ComposePart: [ComposeDiagnostic]] = [:]
        for diagnostic in Self.inFileOrder(errors + warnings) {
            guard let part = parts[diagnostic], unused(part) else { continue }
            withheld[part, default: []].append(diagnostic)
        }
        let taken = Set(withheld.values.joined())
        errors.removeAll(where: taken.contains)
        warnings.removeAll(where: taken.contains)
        return withheld
    }

    /// Throw what was found, if any of it stops the project from running.
    func throwIfFailed() throws {
        guard errors.isEmpty else { throw ComposeError(Self.inFileOrder(errors)) }
    }

    /// The diagnostics the way someone reading the files meets them: file by file in the
    /// order the files were first mentioned, top to bottom, and the ones about no place in
    /// particular last.
    static func inFileOrder(_ diagnostics: [ComposeDiagnostic]) -> [ComposeDiagnostic] {
        var files: [String] = []
        for diagnostic in diagnostics {
            if let file = diagnostic.location?.file, !files.contains(file) { files.append(file) }
        }
        func rank(_ diagnostic: ComposeDiagnostic) -> (Int, Int, Int) {
            guard let location = diagnostic.location, let file = files.firstIndex(of: location.file) else {
                return (files.count, 0, 0)
            }
            return (file, location.line, location.column)
        }
        return diagnostics.enumerated().sorted { first, second in
            let (a, b) = (rank(first.element), rank(second.element))
            return a == b ? first.offset < second.offset : a < b
        }.map(\.element)
    }
}
