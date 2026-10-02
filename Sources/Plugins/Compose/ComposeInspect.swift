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
import ContainerCommands
import ContainerCompose
import ContainerLog
import ContainerVersion
import ContainerizationError
import Darwin
import Foundation

struct ComposePs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List the project's containers")

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .shortAndLong, help: "Include containers that are not running")
    var all = false

    @Flag(name: .shortAndLong, help: "Print only container names")
    var quiet = false

    @Flag(name: .long, help: "Print the services that have a container, one per line")
    var services = false

    @Option(name: .long, help: "Output format: table or json")
    var format = "table"

    func validate() throws {
        guard ["table", "json"].contains(format) else { throw ValidationError("--format takes table or json") }
    }

    func run() async throws {
        let project = ComposeProject(name: try await compose.resolvedProjectName())
        let containers = try await project.containers().filter { all || $0.state != .stopped }
        if services {
            var seen = Set<String>()
            for service in containers.compactMap(\.service) where seen.insert(service).inserted {
                print(service)
            }
            return
        }
        if quiet {
            containers.forEach { print($0.id) }
            return
        }
        if format == "json" {
            let rows = containers.map { container -> [String: Any] in
                var row: [String: Any] = [
                    "Name": container.id, "Service": container.service ?? "", "Project": project.name, "Image": container.image,
                    "State": Self.state(of: container), "Ports": container.ports,
                ]
                row["ExitCode"] = container.exitCode.map { Int($0) }
                return row
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let rows =
            [["NAME", "SERVICE", "IMAGE", "STATUS", "PORTS"]]
            + containers.map { [$0.id, $0.service ?? "", $0.image, Self.state(of: $0), $0.ports.joined(separator: ", ")] }
        print(Self.table(rows))
    }

    /// What a container is doing, in a word. One whose process ended by itself says how;
    /// one that was stopped, or never started, is stopped.
    static func state(of container: ComposeContainer) -> String {
        switch container.state {
        case .running: return "running"
        case .changing: return "stopping"
        case .stopped: return container.exitCode.map { "exited (\($0))" } ?? "stopped"
        }
    }

    /// Rows in columns as wide as their widest cell, two spaces apart.
    static func table(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

/// A container whose output is printed, and the name its lines are printed under.
struct LogSource: Sendable {
    let container: String
    let label: String
}

/// Prints the output of several containers, each line under the name of the container it
/// came from.
///
/// The engine keeps one log per container and no time for a line, so what was written
/// before the command started is printed container by container; what comes after is
/// printed as it arrives.
struct LogPrinter: Sendable {
    let sources: [LogSource]
    let prefixed: Bool
    var tail: Int?

    func print(follow: Bool) async throws {
        let width = sources.map(\.label.count).max() ?? 0
        let client = ContainerClient()
        var handles: [(LogSource, FileHandle)] = []
        for source in sources {
            guard let handle = try await client.logs(id: source.container).first else { continue }
            handles.append((source, handle))
        }
        let output = OutputLines()
        for (source, handle) in handles {
            let data = (try? handle.readToEnd()) ?? Data()
            let prefix = prefix(for: source, width: width)
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            if let tail { lines = Array(lines.suffix(tail)) }
            for line in lines { output.write(prefix + line) }
        }
        guard follow else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (source, handle) in handles {
                let prefix = prefix(for: source, width: width)
                group.addTask {
                    let pending = PendingLine()
                    try await LogFileFollow.follow(handle) { data in
                        for line in pending.lines(adding: data) { output.write(prefix + line) }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func prefix(for source: LogSource, width: Int) -> String {
        prefixed ? source.label.padding(toLength: width, withPad: " ", startingAt: 0) + " | " : ""
    }
}

/// Whole lines out of data that arrives in pieces.
private final class PendingLine: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func lines(adding data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
    }
}

/// Standard output, one whole line at a time, from however many tasks.
private final class OutputLines: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        lock.withLock {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }
}

struct ComposeLogs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Print the output of the project's containers")

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .shortAndLong, help: "Keep printing as the containers write")
    var follow = false

    @Option(name: [.customShort("n"), .long], help: .init("Lines to print from the end of each container's output (default: all)", valueName: "lines"))
    var tail: Int?

    @Flag(name: .customLong("no-log-prefix"), help: "Print the lines without the name of the container they came from")
    var noPrefix = false

    @Argument(help: "Services whose output to print (default: all)")
    var services: [String] = []

    func run() async throws {
        let project = ComposeProject(name: try await compose.resolvedProjectName())
        let containers = try await project.containers()
        for service in services where !containers.contains(where: { $0.service == service }) {
            throw ComposeError("the project \(project.name) has no container for a service named '\(service)'")
        }
        let chosen = containers.filter { services.isEmpty || services.contains($0.service ?? "") }
        var printer = LogPrinter(sources: chosen.map { LogSource(container: $0.id, label: $0.id) }, prefixed: !noPrefix)
        printer.tail = tail
        try await printer.print(follow: follow)
    }
}

struct ComposeExec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command in a service's running container",
        discussion: "With a terminal attached the command gets one, and standard input stays open, as a shell needs.")

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .shortAndLong, help: "Run the command and return")
    var detach = false

    @Flag(name: [.customShort("T"), .customLong("no-tty")], help: "Do not give the command a terminal")
    var noTTY = false

    @Option(name: .shortAndLong, help: .init("Set an environment variable (repeatable)", valueName: "key=value"))
    var env: [String] = []

    @Option(name: [.customShort("w"), .customLong("workdir")], help: .init("Working directory for the command", valueName: "dir"))
    var workdir: String?

    @Option(name: .shortAndLong, help: .init("User to run the command as (name|uid[:gid])", valueName: "user"))
    var user: String?

    @Argument(help: "Service")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "Command and its arguments")
    var command: [String]

    func run() async throws {
        let project = ComposeProject(name: try await compose.resolvedProjectName())
        guard let container = try await project.containers().first(where: { $0.service == service }) else {
            throw ComposeError("the project \(project.name) has no container for a service named '\(service)'")
        }
        var arguments: [String] = []
        if detach {
            arguments.append("--detach")
        } else {
            arguments.append("--interactive")
            if !noTTY, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 { arguments.append("--tty") }
        }
        for variable in env { arguments.append(contentsOf: ["--env", variable]) }
        if let workdir { arguments.append(contentsOf: ["--workdir", workdir]) }
        if let user { arguments.append(contentsOf: ["--user", user]) }
        let exec = try Application.ContainerExec.parse(arguments + [container.id] + command)
        try await exec.run()
    }
}

struct ComposeVersion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version of compose",
        discussion: "The same as --version. Scripts written for another compose run it to find out whether compose is there.")

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .long, help: "Print the version number and nothing else")
    var short = false

    @Option(name: .long, help: "How to print it: pretty or json (also -f, as other compose tools spell it)")
    var format: ComposeVersionReport.Format?

    func run() {
        print(
            ComposeVersionReport.render(
                line: ReleaseVersion.singleLine(appName: "compose"), version: ReleaseVersion.version(), short: short,
                format: ComposeVersionReport.format(named: format, files: compose.files)))
    }
}

struct ComposeConfig: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Check the compose files and print the project they come to",
        discussion: """
            Prints the project as one compose file: the files merged, variables substituted, \
            short forms spelled out. With --commands it prints the container commands that \
            make the project by hand.
            """)

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .long, help: "Print the container commands the project comes to")
    var commands = false

    @Flag(name: .long, help: "Print the names of the services")
    var services = false

    @Flag(name: .long, help: "Print the names of the volumes")
    var volumes = false

    @Flag(name: .long, help: "Print the images the services run")
    var images = false

    @Flag(name: .shortAndLong, help: "Only check the files; print nothing when they are fine")
    var quiet = false

    func run() async throws {
        let reporter = ConsoleReporter()
        let definition = try await compose.definition()
        // The plan is what finds the names and values the engine would refuse.
        let plan = try ProjectPlan.make(definition)
        for warning in ComposeDiagnostic.lines(plan.warnings) where !quiet {
            reporter.warn(warning)
        }
        if quiet { return }
        if commands {
            plan.commandLines.forEach { print($0) }
        } else if services {
            plan.services.forEach { print($0.service) }
        } else if volumes {
            plan.volumes.forEach { print($0.name) }
        } else if images {
            var seen = Set<String>()
            for service in plan.services where seen.insert(service.image).inserted { print(service.image) }
        } else {
            // What does not run was not checked, and what is wrong with it is not something
            // the project printed from it would carry.
            for (part, errors) in definition.unread {
                reporter.warn("\(part.leftOut) (\(errors[0]))")
            }
            print(try definition.yaml(), terminator: "")
        }
    }
}
