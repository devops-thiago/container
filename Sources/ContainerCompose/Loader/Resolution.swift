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

import ContainerResource
import Foundation

/// Turning what the files say into the project they describe: defaults filled in, env files
/// read, and every reference from one part of the project to another checked.
struct Resolver {
    let context: DecodeContext
    /// The project's variables, the env files under the environment compose runs in: what
    /// a name without a value takes its value from.
    let environment: [String: String]
    /// Reads a file's text. A seam for tests; the default reads from disk.
    var read: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }
    var fileManager = FileManager.default

    private var diagnostics: DiagnosticCollector { context.diagnostics }

    func resolve(_ raw: RawProject) -> ComposeFile {
        let services = raw.services.keys.sorted().map { service($0, raw.services[$0] ?? RawService(), in: raw) }
        let networks = raw.networks.keys.sorted().map { key -> ComposeNetwork in
            let declared = raw.networks[key] ?? RawNetwork()
            var network = ComposeNetwork(key: key)
            network.name = declared.name
            network.external = declared.external ?? false
            network.isInternal = declared.isInternal ?? false
            network.subnet = declared.subnet
            network.labels = declared.labels ?? [:]
            return network
        }
        let volumes = raw.volumes.keys.sorted().map { key -> ComposeVolume in
            let declared = raw.volumes[key] ?? RawVolume()
            var volume = ComposeVolume(key: key)
            volume.name = declared.name
            volume.external = declared.external ?? false
            volume.labels = declared.labels ?? [:]
            return volume
        }
        if raw.services.isEmpty {
            diagnostics.error("services", "the project has no services")
        }
        return ComposeFile(name: raw.name, services: services, networks: networks, volumes: volumes)
    }

    private func service(_ name: String, _ raw: RawService, in project: RawProject) -> ComposeService {
        let path = "services.\(name)"
        var service = ComposeService(name: name)
        service.location = raw.location
        // Where a setting of this service is written; the service itself when a merge
        // key brought the setting in.
        func location(of key: String) -> SourceLocation? { raw.keyLocations[key] ?? raw.location }

        if name.isEmpty || !name.allSatisfy({ $0 == "_" || $0 == "-" || $0 == "." || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
            diagnostics.error(path, "a service name is letters, digits, '.', '_' and '-'", at: raw.location)
        }

        service.image = raw.image.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        if let declared = raw.build {
            var build = ComposeBuild(context: declared.context ?? context.projectDirectory.standardizedFileURL.path)
            build.dockerfile = declared.dockerfile
            build.target = declared.target
            build.labels = declared.labels ?? [:]
            build.noCache = declared.noCache ?? false
            build.platforms = declared.platforms ?? []
            for (key, value) in declared.args ?? [:] {
                if let value = value ?? environment[key] { build.args[key] = value }
            }
            service.build = build
        }
        if service.image == nil, service.build == nil {
            diagnostics.error(path, "a service needs an image, or a build that makes one", at: raw.location)
        }

        service.command = nonEmpty(raw.command, "\(path).command", at: location(of: "command"))
        service.entrypoint = nonEmpty(raw.entrypoint, "\(path).entrypoint", at: location(of: "entrypoint"))
        service.environment = self.environment(of: raw, path: path)
        service.ports = raw.ports ?? []
        service.mounts = mounts(raw.mounts ?? [], path: "\(path).volumes", at: location(of: "volumes"), in: project)
        service.dependsOn = (raw.dependsOn ?? []).sorted { $0.service < $1.service }
        for dependency in service.dependsOn {
            let dependencyPath = "\(path).depends_on.\(dependency.service)"
            guard let target = project.services[dependency.service] else {
                diagnostics.error(dependencyPath, "there is no service named '\(dependency.service)'", at: location(of: "depends_on"))
                continue
            }
            if dependency.service == name {
                diagnostics.error(dependencyPath, "a service cannot depend on itself", at: location(of: "depends_on"))
            }
            if dependency.condition == .healthy, healthcheck(target.healthcheck, path: nil) == nil {
                diagnostics.error(
                    dependencyPath,
                    "waits for '\(dependency.service)' to be healthy, and that service has no healthcheck with a test. A health check built into an image is not read: give the service a healthcheck here",
                    at: location(of: "depends_on"))
            }
        }
        service.healthcheck = healthcheck(raw.healthcheck, path: "\(path).healthcheck")
        service.restart = raw.restart
        if let containerName = raw.containerName {
            if ManagedContainer.nameValid(containerName) {
                service.containerName = containerName
            } else {
                diagnostics.error(
                    "\(path).container_name",
                    "'\(containerName)' is not a container name: 2 to 63 letters, digits, '.', '_' and '-', starting with a letter or digit",
                    at: location(of: "container_name"))
            }
        }
        service.networks = raw.networks ?? []
        for network in service.networks where network.key != "default" && project.networks[network.key] == nil {
            diagnostics.error(
                "\(path).networks", "the network '\(network.key)' is not defined under the top-level networks", at: location(of: "networks"))
        }
        service.profiles = raw.profiles ?? []
        service.pullPolicy = raw.pullPolicy
        service.workingDirectory = raw.workingDirectory
        service.user = raw.user
        service.labels = raw.labels ?? [:]
        service.platform = raw.platform
        service.tmpfs = raw.tmpfs ?? []
        service.ulimits = (raw.ulimits ?? []).sorted { $0.name < $1.name }
        service.capAdd = raw.capAdd ?? []
        service.capDrop = raw.capDrop ?? []
        service.readOnly = raw.readOnly ?? false
        service.useInit = raw.useInit ?? false
        service.tty = raw.tty ?? false
        service.shmSize = raw.shmSize
        service.dns = raw.dns ?? []
        service.dnsSearch = raw.dnsSearch ?? []
        service.dnsOptions = raw.dnsOptions ?? []
        service.stopSignal = raw.stopSignal
        service.stopGracePeriod = raw.stopGracePeriod
        service.cpus = raw.cpus
        if let cpus = raw.cpus, cpus <= 0 {
            diagnostics.error("\(path).cpus", "expected a number above zero, found \(cpus)", at: location(of: "cpus"))
        }
        service.memory = raw.memory
        service.sysctls = raw.sysctls ?? [:]
        service.hostname = raw.hostname
        service.extraHosts = raw.extraHosts ?? []
        return service
    }

    private func nonEmpty(_ words: [String]?, _ path: String, at location: SourceLocation?) -> [String]? {
        guard let words else { return nil }
        guard words.isEmpty else { return words }
        diagnostics.warn(path, "ignored: an empty list cannot take the place of what the image runs", at: location)
        return nil
    }

    /// The service's environment: each env file in turn, then `environment`, a later value
    /// replacing an earlier one. A name with no value takes the one compose runs with.
    private func environment(of raw: RawService, path: String) -> [String: String] {
        var result: [String: String] = [:]
        for file in raw.envFiles ?? [] {
            guard fileManager.fileExists(atPath: file.path) else {
                if file.required {
                    diagnostics.error("\(path).env_file", "\(file.path) does not exist", at: file.location)
                }
                continue
            }
            do {
                let lookup = environment
                let entries = try DotEnv.parse(try read(file.path), file: file.path) { lookup[$0] }
                for entry in entries {
                    if let value = entry.value ?? environment[entry.key] { result[entry.key] = value }
                }
            } catch let error as ComposeError {
                for diagnostic in error.diagnostics {
                    diagnostics.error("\(path).env_file", diagnostic.message, at: diagnostic.location ?? file.location)
                }
            } catch {
                diagnostics.error("\(path).env_file", "\(file.path) could not be read: \(error.localizedDescription)", at: file.location)
            }
        }
        for (key, value) in raw.environment ?? [:] {
            if let value = value ?? environment[key] { result[key] = value }
        }
        return result
    }

    private func mounts(_ mounts: [ComposeMount], path: String, at location: SourceLocation?, in project: RawProject) -> [ComposeMount] {
        for mount in mounts {
            switch mount.kind {
            case .volume(let key) where project.volumes[key] == nil:
                diagnostics.error(path, "the volume '\(key)' is not defined under the top-level volumes", at: location)
            case .bind(let source):
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: source, isDirectory: &isDirectory), !isDirectory.boolValue {
                    diagnostics.error(
                        path,
                        "not supported on this engine: \(source) is a file, and only folders can be mounted. Mount the folder that holds it",
                        at: location)
                }
            default:
                break
            }
        }
        return mounts
    }

    /// The check a service runs, or nil when it has none or turns it off. With a `path`,
    /// a check that cannot be run is reported there.
    private func healthcheck(_ raw: RawHealthcheck?, path: String?) -> ComposeHealthcheck? {
        guard let raw, raw.disable != true else { return nil }
        guard let test = raw.test, !test.isEmpty else {
            if let path {
                diagnostics.warn(
                    path,
                    "ignored: it has no test, and a health check built into an image is not read, so there is nothing to change the timing of",
                    at: raw.location)
            }
            return nil
        }
        if let path, let retries = raw.retries, retries < 0 {
            diagnostics.error("\(path).retries", "expected zero or more, found \(retries)", at: raw.location)
        }
        return ComposeHealthcheck(
            test: test,
            interval: raw.interval ?? 30,
            timeout: raw.timeout ?? 30,
            retries: max(raw.retries ?? 3, 0),
            startPeriod: raw.startPeriod ?? 0,
            startInterval: raw.startInterval)
    }
}
