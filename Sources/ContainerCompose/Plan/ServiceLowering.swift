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
import ContainerResource
import CryptoKit
import Foundation

/// The options of `container run`, read by the parser the command itself uses. A service
/// is lowered onto a command line and the command line is read back through this, so the
/// flags compose hands the engine are the ones the same line typed at a prompt would.
struct RunOptions: ParsableArguments {
    @OptionGroup var process: Flags.Process
    @OptionGroup var resource: Flags.Resource
    @OptionGroup var management: Flags.Management
    @OptionGroup var registry: Flags.Registry
    @OptionGroup var imageFetch: Flags.ImageFetch

    @Argument var image: String

    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
}

/// A command line being put together, option by option.
struct ArgumentList {
    private(set) var words: [String] = []

    mutating func flag(_ name: String) {
        words.append(name)
    }

    /// An option and its value. A value that starts with a dash is joined to its option
    /// with `=`, so that it is not read as an option itself.
    mutating func option(_ name: String, _ value: String) {
        if value.hasPrefix("-") {
            words.append("\(name)=\(value)")
        } else {
            words.append(contentsOf: [name, value])
        }
    }

    /// The values an option was given, in order, in a list of words built by `option`.
    static func values(of name: String, in words: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == name, index + 1 < words.count {
                values.append(words[index + 1])
                index += 2
            } else {
                if word.hasPrefix(name + "=") { values.append(String(word.dropFirst(name.count + 1))) }
                index += 1
            }
        }
        return values
    }
}

/// What the plan needs to know about the project to lower one of its services.
struct LoweringContext {
    let project: String
    let directory: String
    let configFiles: [String]
    /// The engine's name for each network and volume the files declare, by key.
    let networkNames: [String: String]
    let volumeNames: [String: String]
    let diagnostics: DiagnosticCollector
}

enum ServiceLowering {
    /// The least memory a container can boot with. A compose file written for a shared
    /// kernel often asks for less.
    static let minimumMemoryBytes: Double = 200 * 1024 * 1024

    static func plan(_ service: ComposeService, dependencies: [ComposeDependency], in context: LoweringContext) -> ServicePlan {
        let path = "services.\(service.name)"
        let diagnostics = context.diagnostics
        let containerName = service.containerName ?? "\(context.project)-\(service.name)-1"
        if !ManagedContainer.nameValid(containerName) {
            diagnostics.error(
                path,
                "its container would be named '\(containerName)', which is longer than the 63 characters a container name can have; give the project a shorter name with -p, or the service a container_name",
                at: service.location)
        }
        let image = service.image ?? "\(context.project)-\(service.name)"

        var options = ArgumentList()
        options.flag("--detach")
        options.option("--name", containerName)
        if let hostname = service.hostname { options.option("--hostname", hostname) }

        // Networks, in the order the service lists them: the first is the one the
        // container's own name belongs to.
        let attachments = service.networks.isEmpty ? [ComposeServiceNetwork(key: "default")] : service.networks
        for attachment in attachments {
            guard let network = context.networkNames[attachment.key] else { continue }
            var specification = network
            var aliases: [String] = []
            for alias in [service.name] + attachment.aliases where !aliases.contains(alias) {
                if (try? Parser.networkAlias(alias)) != nil {
                    aliases.append(alias)
                } else {
                    diagnostics.warn(
                        path, "'\(alias)' cannot be a name on a network; the other services reach this one as \(containerName)",
                        at: service.location)
                }
            }
            specification += aliases.map { ",alias=\($0)" }.joined()
            if let mac = attachment.macAddress { specification += ",mac=\(mac)" }
            options.option("--network", specification)
        }

        var ephemeralPorts: [ComposePort] = []
        for port in service.ports {
            guard let published = port.published else {
                ephemeralPorts.append(port)
                continue
            }
            options.option("--publish", publishSpecification(port, published: published))
        }

        var bindSources: [String] = []
        for mount in service.mounts {
            let suffix = mount.readOnly ? ":ro" : ""
            switch mount.kind {
            case .bind(let source):
                bindSources.append(source)
                options.option("--volume", "\(source):\(mount.target)\(suffix)")
            case .volume(let key):
                guard let volume = context.volumeNames[key] else { continue }
                options.option("--volume", "\(volume):\(mount.target)\(suffix)")
            case .anonymous:
                options.option("--volume", mount.target)
            case .tmpfs(let size):
                options.option("--tmpfs", mount.target + (size.map { ":size=\($0)" } ?? ""))
            }
        }
        for tmpfs in service.tmpfs { options.option("--tmpfs", tmpfs) }

        for key in service.environment.keys.sorted() {
            options.option("--env", "\(key)=\(service.environment[key] ?? "")")
        }

        if let workingDirectory = service.workingDirectory { options.option("--workdir", workingDirectory) }
        if let user = service.user { options.option("--user", user) }
        if let platform = service.platform { options.option("--platform", platform) }

        // The engine's --entrypoint is one word; the rest of a longer entrypoint goes
        // in front of the command, which is where it ends up either way.
        var command = service.command ?? []
        if let entrypoint = service.entrypoint, let executable = entrypoint.first {
            options.option("--entrypoint", executable)
            command = Array(entrypoint.dropFirst()) + command
        }

        if let cpus = service.cpus {
            let whole = max(Int(cpus.rounded(.up)), 1)
            if Double(whole) != cpus {
                diagnostics.warn("\(path).cpus", "\(format(cpus)) becomes \(whole): a container gets whole CPUs", at: service.location)
            }
            options.option("--cpus", "\(whole)")
        }
        if let memory = service.memory {
            if let bytes = DecodeContext.bytes(memory), bytes < minimumMemoryBytes {
                diagnostics.warn(
                    "\(path).memory", "\(memory) becomes 200m: a container is a virtual machine, and that is the least one boots with",
                    at: service.location)
                options.option("--memory", "200m")
            } else {
                options.option("--memory", memory)
            }
        }

        if service.readOnly { options.flag("--read-only") }
        if service.useInit { options.flag("--init") }
        if service.tty { options.flag("--tty") }
        for capability in service.capAdd { options.option("--cap-add", capability) }
        for capability in service.capDrop { options.option("--cap-drop", capability) }
        if let shmSize = service.shmSize { options.option("--shm-size", shmSize) }
        for limit in service.ulimits {
            options.option("--ulimit", "\(limit.name)=\(limit.soft)" + (limit.hard.map { ":\($0)" } ?? ""))
        }
        for key in service.sysctls.keys.sorted() {
            options.option("--sysctl", "\(key)=\(service.sysctls[key] ?? "")")
        }
        for host in service.extraHosts { options.option("--add-host", host) }
        for server in service.dns { options.option("--dns", server) }
        for domain in service.dnsSearch { options.option("--dns-search", domain) }
        for option in service.dnsOptions { options.option("--dns-option", option) }
        if let restart = service.restart { options.option("--restart", restart) }
        switch service.pullPolicy {
        case .always: options.option("--pull", "always")
        case .never: options.option("--pull", "never")
        case .missing, .build, nil: break
        }

        // What the service is, as labels: the ones the file gives it, then what compose
        // needs to find the container again and to start it in order without the file.
        var labels = service.labels
        if !dependencies.isEmpty { labels[ComposeLabels.dependsOn] = ComposeLabels.encode(dependencies) }
        if let healthcheck = service.healthcheck, let encoded = ComposeLabels.encode(healthcheck) {
            labels[ComposeLabels.healthcheck] = encoded
        }
        let stopTimeout = service.stopGracePeriod.map { Int($0.rounded(.up)) }
        if let stopTimeout { labels[ComposeLabels.stopGracePeriod] = "\(stopTimeout)" }
        for key in labels.keys.sorted() {
            options.option("--label", "\(key)=\(labels[key] ?? "")")
        }

        // Everything so far is what the container is made from, and goes into the digest:
        // a change to any of it is a reason for `up` to make the container again. Where
        // the project sits on disk is not, so those labels come after.
        let digestInput =
            [image] + options.words + ["--"] + command + ephemeralPorts.map { "any:\($0.target)/\($0.transport.rawValue)" }
            + [service.stopSignal ?? ""]
        let configHash = SHA256.hash(data: Data(digestInput.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()

        let bookkeeping = [
            (ComposeLabels.project, context.project),
            (ComposeLabels.service, service.name),
            (ComposeLabels.containerNumber, "1"),
            (ComposeLabels.oneoff, "False"),
            (ComposeLabels.workingDirectory, context.directory),
            (ComposeLabels.configFiles, context.configFiles.joined(separator: ",")),
            (ComposeLabels.configHash, configHash),
        ]
        for (key, value) in bookkeeping {
            if labels[key] != nil {
                diagnostics.error("\(path).labels", "'\(key)' is a label compose sets itself", at: service.location)
            }
            options.option("--label", "\(key)=\(value)")
        }

        check(options.words, path: path, at: service.location, diagnostics: diagnostics)

        return ServicePlan(
            service: service.name,
            containerName: containerName,
            image: image,
            build: service.build.map { build($0, tag: image) },
            pullPolicy: service.pullPolicy ?? .missing,
            platform: service.platform,
            options: options.words,
            command: command,
            ephemeralPorts: ephemeralPorts,
            dependencies: dependencies,
            healthcheck: service.healthcheck,
            stopSignal: service.stopSignal,
            stopTimeout: stopTimeout,
            bindSources: bindSources,
            configHash: configHash)
    }

    /// `[host-ip:]host-port:container-port[/protocol]`, as `--publish` takes it.
    static func publishSpecification(_ port: ComposePort, published: String) -> String {
        var specification = ""
        if let address = port.hostIP {
            specification += (address.contains(":") ? "[\(address)]" : address) + ":"
        }
        specification += "\(published):\(port.target)"
        if port.transport == .udp { specification += "/udp" }
        return specification
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private static func build(_ build: ComposeBuild, tag: String) -> BuildPlan {
        var arguments = ArgumentList()
        arguments.option("--tag", tag)
        if let dockerfile = build.dockerfile {
            let path = dockerfile.hasPrefix("/") ? dockerfile : URL(fileURLWithPath: build.context).appendingPathComponent(dockerfile).standardizedFileURL.path
            arguments.option("--file", path)
        }
        for key in build.args.keys.sorted() {
            arguments.option("--build-arg", "\(key)=\(build.args[key] ?? "")")
        }
        if let target = build.target { arguments.option("--target", target) }
        for key in build.labels.keys.sorted() {
            arguments.option("--label", "\(key)=\(build.labels[key] ?? "")")
        }
        if build.noCache { arguments.flag("--no-cache") }
        for platform in build.platforms { arguments.option("--platform", platform) }
        return BuildPlan(context: build.context, tag: tag, arguments: arguments.words + [build.context])
    }

    /// Hand the values to the parsers `container run` reads them with, so that one the
    /// engine would refuse when the container is created is refused now, with the service
    /// named. The command line as a whole is read by the command's own option parser when
    /// the container is made.
    private static func check(_ options: [String], path: String, at location: SourceLocation?, diagnostics: DiagnosticCollector) {
        func values(_ name: String) -> [String] { ArgumentList.values(of: name, in: options) }
        let checks: [() throws -> Void] = [
            { _ = try Parser.publishPorts(values("--publish")) },
            { _ = try values("--network").map { try Parser.network($0) } },
            { _ = try Parser.tmpfsMounts(values("--tmpfs")) },
            { _ = try Parser.labels(values("--label")) },
            { _ = try Parser.sysctls(values("--sysctl")) },
            { _ = try values("--hostname").first.map(Parser.hostname) },
            { _ = try Parser.extraHosts(values("--add-host")) },
            { _ = try values("--restart").first.map(Parser.restartPolicy) },
            { _ = try Parser.capabilities(capAdd: values("--cap-add"), capDrop: values("--cap-drop")) },
            { _ = try Parser.rlimits(values("--ulimit")) },
            { _ = try values("--memory").first.map(Parser.memoryStringAsMiB) },
            { _ = try values("--shm-size").first.map(Parser.memoryStringAsBytes) },
        ]
        for check in checks {
            do {
                try check()
            } catch {
                diagnostics.error(path, "\(error)", at: location)
            }
        }
    }
}
