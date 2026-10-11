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

/// What a compose project comes to on this engine: the networks, volumes and containers
/// `up` makes, in the order it makes them.
public struct ProjectPlan: Sendable, Equatable {
    public let name: String
    public let directory: String
    public let configFiles: [String]
    public let networks: [NetworkPlan]
    public let volumes: [VolumePlan]
    /// The services in start order: each one after everything it depends on.
    public let services: [ServicePlan]
    /// Every service the files define, planned or not. A container of the project whose
    /// service is not among these is one the files no longer account for.
    public let definedServices: [String]
    /// What the files ask for that will not happen, or not as written.
    public let warnings: [ComposeDiagnostic]

    public func service(_ name: String) -> ServicePlan? {
        services.first { $0.service == name }
    }
}

public struct NetworkPlan: Sendable, Equatable {
    /// The key the compose files know the network by.
    public let key: String
    /// The network's name on the engine.
    public let name: String
    /// Someone else's network: it has to exist, and `down` leaves it.
    public let external: Bool
    public let isInternal: Bool
    public let subnet: String?
    public let labels: [String: String]
}

public struct VolumePlan: Sendable, Equatable {
    public let key: String
    public let name: String
    public let external: Bool
    public let labels: [String: String]
}

public struct BuildPlan: Sendable, Equatable {
    public let context: String
    /// The name the built image gets, which is the one the service runs.
    public let tag: String
    /// The arguments of the `container build` that makes the image.
    public let arguments: [String]
}

public struct ServicePlan: Sendable, Equatable {
    public let service: String
    public let containerName: String
    /// The image the container runs: the service's, or the name its build is tagged with.
    public let image: String
    /// The service names its image with `image:`. One that only builds runs an image named
    /// after the project and the service, which no registry is asked for.
    public let namesImage: Bool
    public let build: BuildPlan?
    public let pullPolicy: ComposePullPolicy
    /// The platform the service asks for. nil is this Mac's.
    public let platform: String?
    /// The options of the `container run` that makes this service's container.
    public let options: [String]
    /// What follows the image on that command line: what the container runs.
    public let command: [String]
    /// Ports published on whichever host port is free when the container is created.
    public let ephemeralPorts: [ComposePort]
    /// The services this one waits for, among those in the plan.
    public let dependencies: [ComposeDependency]
    public let healthcheck: ComposeHealthcheck?
    public let stopSignal: String?
    /// Seconds a stop waits before it kills. nil is the engine's default.
    public let stopTimeout: Int?
    /// The folders on this Mac the container mounts.
    public let bindSources: [String]
    /// A digest of everything above that the container is made from.
    public let configHash: String

    /// The whole `container run` command line, without the command's own name.
    public var arguments: [String] { options + [image] + command }

    /// The ports the service publishes, as `[address:]host:container[/protocol]`. A port
    /// that takes whichever host port is free has none before the colon.
    public var publishedPorts: [String] {
        ArgumentList.values(of: "--publish", in: options)
            + ephemeralPorts.map { port in
                (port.hostIP.map { "\($0):" } ?? "") + ":\(port.target)" + (port.transport == .udp ? "/udp" : "")
            }
    }
}

extension ProjectPlan {
    /// Which of a project's services a command is about.
    public struct Selection: Sendable {
        /// The services named on the command line. Empty means every service whose
        /// profiles are active.
        public var services: [String]
        /// Whether what the selected services depend on comes along.
        public var includesDependencies: Bool

        public init(services: [String] = [], includesDependencies: Bool = true) {
            self.services = services
            self.includesDependencies = includesDependencies
        }
    }

    /// Plan a project. Throws `ComposeError` with everything that keeps it from running.
    public static func make(_ definition: ComposeDefinition, selection: Selection = Selection()) throws -> ProjectPlan {
        let diagnostics = DiagnosticCollector()
        let file = definition.file

        func enabled(_ service: ComposeService) -> Bool {
            service.isActive(in: definition.profiles)
        }

        // The services asked for. One named on the command line runs whatever its profiles.
        for name in selection.services where file.service(name) == nil {
            diagnostics.error("", "there is no service named '\(name)'")
        }
        try diagnostics.throwIfFailed()
        let targets = selection.services.isEmpty ? file.services.filter(enabled).map(\.name) : selection.services
        let named = Set(selection.services)

        // What each of them waits for. A dependency outside the active profiles is an
        // error when it is required, and dropped when it is not.
        var dependencies: [String: [ComposeDependency]] = [:]
        var pending = targets
        while let name = pending.popLast() {
            guard dependencies[name] == nil, let service = file.service(name) else { continue }
            var kept: [ComposeDependency] = []
            for dependency in service.dependsOn {
                guard let target = file.service(dependency.service) else { continue }
                guard enabled(target) || named.contains(target.name) else {
                    if dependency.required {
                        diagnostics.error(
                            "services.\(name).depends_on.\(dependency.service)",
                            "'\(dependency.service)' is in the profile \(target.profiles.joined(separator: ", ")), which is not active; add --profile \(target.profiles.first ?? "")",
                            at: service.location)
                    } else {
                        diagnostics.warn(
                            "services.\(name).depends_on.\(dependency.service)",
                            "'\(dependency.service)' is not started: its profile is not active and the dependency is not required",
                            at: service.location)
                    }
                    continue
                }
                guard selection.includesDependencies || targets.contains(dependency.service) else { continue }
                kept.append(dependency)
                pending.append(dependency.service)
            }
            dependencies[name] = kept
        }
        try diagnostics.throwIfFailed()

        let order = try DependencyGraph(dependencies: dependencies.mapValues { $0.map(\.service) }).startOrder()
        let planned = order.compactMap { file.service($0) }
        let networkKeys = Set(planned.flatMap(\.networkKeys))
        let volumeKeys = Set(planned.flatMap(\.volumeKeys))

        // What reading the files held back, about the parts this plan uses after all: a
        // service named in spite of its profiles, and the networks and volumes it brings.
        // An error among them may have left the part half read, so nothing is made of it.
        let parts: [ComposePart] =
            planned.map { .service($0.name) } + networkKeys.sorted().map { .network($0) } + volumeKeys.sorted().map { .volume($0) }
        for diagnostic in parts.flatMap({ definition.withheld[$0] ?? [] }) {
            diagnostics.add(diagnostic)
        }
        try diagnostics.throwIfFailed()

        // The networks and volumes those services use, under their names on the engine.
        var networks: [NetworkPlan] = []
        var networkNames: [String: String] = [:]
        for key in networkKeys.sorted() {
            let declared = file.networks.first { $0.key == key } ?? ComposeNetwork(key: key)
            let name = declared.name ?? "\(definition.name)_\(key)"
            guard NetworkResource.nameValid(name) else {
                diagnostics.error(
                    "networks.\(key)",
                    "'\(name)' is not a network name: up to 63 lowercase letters, digits, '.', '_' and '-', starting and ending with a letter or digit")
                continue
            }
            var labels = declared.labels
            if !declared.external {
                labels[ComposeLabels.project] = definition.name
                labels[ComposeLabels.network] = key
                check(labels: labels, of: "networks.\(key)", diagnostics: diagnostics)
            }
            networkNames[key] = name
            networks.append(
                NetworkPlan(
                    key: key, name: name, external: declared.external, isInternal: declared.isInternal, subnet: declared.subnet, labels: labels))
        }

        var volumes: [VolumePlan] = []
        var volumeNames: [String: String] = [:]
        for key in volumeKeys.sorted() {
            let declared = file.volumes.first { $0.key == key } ?? ComposeVolume(key: key)
            let name = declared.name ?? "\(definition.name)_\(key)"
            guard VolumeResource.nameValid(name) else {
                diagnostics.error("volumes.\(key)", "'\(name)' is not a volume name: letters, digits, '.', '_' and '-', starting with a letter or digit")
                continue
            }
            var labels = declared.labels
            if !declared.external {
                labels[ComposeLabels.project] = definition.name
                labels[ComposeLabels.volume] = key
                check(labels: labels, of: "volumes.\(key)", diagnostics: diagnostics)
            }
            volumeNames[key] = name
            volumes.append(VolumePlan(key: key, name: name, external: declared.external, labels: labels))

            let users = planned.filter { service in service.mounts.contains { $0.kind == .volume(key: key) } }.map(\.name)
            if users.count > 1 {
                diagnostics.warn(
                    "volumes.\(key)",
                    "mounted by \(users.joined(separator: ", ")): a volume is a disk that one running container holds at a time, so these services cannot run at the same time. Services that run together share files through a folder mounted into each"
                )
            }
        }

        let context = LoweringContext(
            project: definition.name,
            directory: definition.directory,
            configFiles: definition.configFiles,
            networkNames: networkNames,
            volumeNames: volumeNames,
            diagnostics: diagnostics)
        let services = planned.map { ServiceLowering.plan($0, dependencies: dependencies[$0.name] ?? [], in: context) }

        // Two services cannot have one container.
        for (name, sharing) in Dictionary(grouping: services, by: \.containerName) where sharing.count > 1 {
            diagnostics.error(
                "", "the services \(sharing.map(\.service).sorted().joined(separator: " and ")) would both be the container '\(name)'")
        }
        try diagnostics.throwIfFailed()

        return ProjectPlan(
            name: definition.name,
            directory: definition.directory,
            configFiles: definition.configFiles,
            networks: networks,
            volumes: volumes,
            services: services,
            definedServices: file.services.map(\.name),
            warnings: definition.warnings + DiagnosticCollector.inFileOrder(diagnostics.warnings))
    }

    private static func check(labels: [String: String], of path: String, diagnostics: DiagnosticCollector) {
        for key in labels.keys.sorted() {
            do {
                try ResourceLabels.validateLabel(key: key, value: labels[key] ?? "")
            } catch {
                diagnostics.error(
                    "\(path).labels",
                    "'\(key)' is not a label this engine takes on a network or a volume: a key is lowercase letters, digits and '-' in parts separated by '.', and key and value together are at most \(ResourceLabels.labelLengthMax) characters"
                )
            }
        }
    }
}
