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
import Darwin
import Foundation

struct ComposeUp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Create and start the project's containers",
        discussion: """
            Makes the project's network and volumes, then every container, then starts them \
            in the order their dependencies give, waiting where a service asks for another \
            to be healthy or to have finished. A container whose service has not changed \
            is left as it is.

            Without --detach the command stays attached: it prints the services' output and, \
            on Control-C, stops them.
            """)

    @ParentCommand var compose: ComposeCommand

    @Flag(name: .shortAndLong, help: "Start the containers and return")
    var detach = false

    @Flag(name: .long, help: "Build images before starting, even those that exist")
    var build = false

    @Option(name: .long, help: .init("Fetch images: always, missing or never (default: each service's pull_policy)", valueName: "policy"))
    var pull: String?

    @Flag(name: .customLong("no-deps"), help: "Leave out the services the named ones depend on")
    var noDependencies = false

    @Flag(name: .customLong("force-recreate"), help: "Make every container again, changed or not")
    var forceRecreate = false

    @Flag(name: .customLong("no-recreate"), help: "Keep existing containers even when their service changed")
    var noRecreate = false

    @Flag(name: .customLong("remove-orphans"), help: "Remove the project's containers that no service accounts for")
    var removeOrphans = false

    @Flag(name: .customLong("no-start"), help: "Create the containers without starting them")
    var noStart = false

    @Flag(name: .long, help: "Wait until every service with a health check is healthy; implies --detach")
    var wait = false

    @OptionGroup(title: "Registry options")
    var registry: Flags.Registry

    @Argument(help: "Services to bring up (default: all)")
    var services: [String] = []

    func validate() throws {
        if let pull, !["always", "missing", "never"].contains(pull) {
            throw ValidationError("--pull takes always, missing or never")
        }
        if forceRecreate && noRecreate {
            throw ValidationError("--force-recreate and --no-recreate cannot both be given")
        }
    }

    func run() async throws {
        let reporter = ConsoleReporter()
        defer { reporter.finishBar() }
        let plan = try await compose.plan(services: services, includesDependencies: !noDependencies, reporter: reporter)

        var hooks = reporter.hooks
        hooks.build = { build, _ in try await runBuild(build.arguments) }
        var options = ComposeProject.UpOptions()
        options.build = build
        options.pull = pull.flatMap(ComposePullPolicy.init(rawValue:))
        options.forceRecreate = forceRecreate
        options.noRecreate = noRecreate
        options.removeOrphans = removeOrphans
        options.wait = wait
        options.start = !noStart

        let scheme = registry.scheme
        let project = ComposeProject(name: plan.name, engine: LiveComposeEngine(registryScheme: { _ in scheme }), hooks: hooks)
        try await project.up(plan, options: options)
        reporter.finishBar()
        guard !detach, !wait, !noStart else { return }

        // Attached: the services' output until they all end or the user has had enough.
        let containers = plan.services.map { LogSource(container: $0.containerName, label: $0.containerName) }
        let interrupted = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await LogPrinter(sources: containers, prefixed: true).print(follow: true)
                return false
            }
            group.addTask {
                await Self.waitForInterrupt()
                return true
            }
            group.addTask {
                try await Self.waitUntilStopped(project)
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard interrupted else { return }
        FileHandle.standardError.write(Data("Stopping the project's containers\n".utf8))
        try await project.stop(services: plan.services.map(\.service))
        throw ExitCode(130)
    }

    /// Returns when the user interrupts the command.
    private static func waitForInterrupt() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let stream = AsyncStream<Void> { continuation in
            let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { continuation.yield() }
                source.resume()
                return source
            }
            continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
        }
        for await _ in stream { return }
    }

    /// Returns when none of the project's containers runs any more.
    private static func waitUntilStopped(_ project: ComposeProject) async throws {
        while try await project.containers().contains(where: { $0.state != .stopped }) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Build an image the way `container build` does, in this process: a plugin cannot start
/// the `container` command itself from inside its sandbox.
func runBuild(_ arguments: [String]) async throws {
    let command = try Application.BuildCommand.parse(arguments)
    try await command.run()
}

struct ComposeDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "down",
        abstract: "Stop and remove the project's containers and networks",
        discussion: """
            Volumes hold data and stay unless --volumes is given. A network or a volume \
            declared external is never the project's to remove.
            """)

    @ParentCommand var compose: ComposeCommand

    @Flag(name: [.customShort("v"), .long], help: "Remove the project's volumes too")
    var volumes = false

    @Flag(name: .customLong("remove-orphans"), help: .hidden)
    var removeOrphans = false

    @Option(name: [.customShort("t"), .long], help: .init("Seconds to wait for each container before killing it", valueName: "seconds"))
    var timeout: Int?

    func run() async throws {
        let reporter = ConsoleReporter()
        let project = ComposeProject(name: try await compose.resolvedProjectName(), hooks: reporter.hooks)
        try await project.down(removeVolumes: volumes, timeout: timeout)
    }
}

struct ComposeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start the project's stopped containers, in dependency order")

    @ParentCommand var compose: ComposeCommand

    @Argument(help: "Services to start (default: all)")
    var services: [String] = []

    func run() async throws {
        let reporter = ConsoleReporter()
        try await ComposeProject(name: try await compose.resolvedProjectName(), hooks: reporter.hooks).start(services: services)
    }
}

struct ComposeStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop the project's running containers, without removing them")

    @ParentCommand var compose: ComposeCommand

    @Option(name: [.customShort("t"), .long], help: .init("Seconds to wait for each container before killing it", valueName: "seconds"))
    var timeout: Int?

    @Argument(help: "Services to stop (default: all)")
    var services: [String] = []

    func run() async throws {
        let reporter = ConsoleReporter()
        try await ComposeProject(name: try await compose.resolvedProjectName(), hooks: reporter.hooks)
            .stop(services: services, timeout: timeout)
    }
}

struct ComposeRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Stop the project's containers and start them again")

    @ParentCommand var compose: ComposeCommand

    @Option(name: [.customShort("t"), .long], help: .init("Seconds to wait for each container before killing it", valueName: "seconds"))
    var timeout: Int?

    @Argument(help: "Services to restart (default: all)")
    var services: [String] = []

    func run() async throws {
        let reporter = ConsoleReporter()
        try await ComposeProject(name: try await compose.resolvedProjectName(), hooks: reporter.hooks)
            .restart(services: services, timeout: timeout)
    }
}

struct ComposePull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull", abstract: "Fetch the images of the project's services")

    @ParentCommand var compose: ComposeCommand

    @OptionGroup(title: "Registry options")
    var registry: Flags.Registry

    @Argument(help: "Services whose images to fetch (default: all)")
    var services: [String] = []

    func run() async throws {
        let reporter = ConsoleReporter()
        defer { reporter.finishBar() }
        let plan = try await compose.plan(services: services, includesDependencies: false, reporter: reporter)
        let scheme = registry.scheme
        try await ComposeProject(name: plan.name, engine: LiveComposeEngine(registryScheme: { _ in scheme }), hooks: reporter.hooks).pull(plan)
    }
}

struct ComposeBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build the images of the services that have a build")

    @ParentCommand var compose: ComposeCommand

    @Argument(help: "Services to build (default: all)")
    var services: [String] = []

    func run() async throws {
        let reporter = ConsoleReporter()
        let plan = try await compose.plan(services: services, includesDependencies: false, reporter: reporter)
        var hooks = reporter.hooks
        hooks.build = { build, _ in try await runBuild(build.arguments) }
        try await ComposeProject(name: plan.name, hooks: hooks).build(plan)
    }
}
