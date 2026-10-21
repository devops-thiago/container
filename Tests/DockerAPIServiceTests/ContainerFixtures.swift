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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

@testable import DockerAPIService

/// Containers, images and create bodies for the container tests.
enum Fixtures {
    static let builtin = "default"
    static let configDigest = "sha256:" + String(repeating: "c", count: 64)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func imageDescription(_ reference: String = "docker.io/library/alpine:latest") -> ImageDescription {
        ImageDescription(
            reference: reference,
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:" + String(repeating: "d", count: 64), size: 1))
    }

    static func image(
        entrypoint: [String]? = nil, cmd: [String]? = ["/bin/sh"], env: [String]? = ["PATH=/usr/bin:/bin"], user: String? = nil,
        workingDir: String? = nil, labels: [String: String]? = nil, stopSignal: String? = nil, healthCheck: HealthCheckConfiguration? = nil,
        architecture: String = "arm64"
    ) -> DockerImageDefaults {
        DockerImageDefaults(
            description: imageDescription(), id: configDigest, platform: Platform(arch: architecture, os: "linux"), user: user, env: env,
            entrypoint: entrypoint, cmd: cmd, workingDir: workingDir, labels: labels, stopSignal: stopSignal, healthCheck: healthCheck)
    }

    static let dockerSocket = "/Users/me/Library/Group Containers/group.example/run/docker.sock"
    static let defaults = DockerCreateDefaults(cpus: 4, memoryInBytes: 1 << 30, dnsDomain: nil, builtinNetwork: builtin, dockerSocket: dockerSocket)

    static let reservation = DockerIdentityReservation(name: "web", dockerID: "abcdef012345" + String(repeating: "0", count: 52))

    /// A create body as JSON, the way the CLI sends one.
    static func body(_ json: String) throws -> DockerContainerCreateBody {
        try JSONDecoder().decode(DockerContainerCreateBody.self, from: Data(json.utf8))
    }

    static func plan(
        _ json: String, image: DockerImageDefaults = image(), defaults: DockerCreateDefaults = defaults, reference: String = "alpine"
    ) throws -> DockerCreatePlan {
        var ports: UInt16 = 40000
        var volumes = 0
        return try ContainerCreateMapper.plan(
            try body(json), reservation: reservation, image: image, imageReference: reference, defaults: defaults,
            allocatePort: {
                ports += 1
                return ports
            },
            newVolumeName: {
                volumes += 1
                return "anon\(volumes)"
            })
    }

    static func configuration(
        id: String, labels: [String: String] = [:], created: Date = now.addingTimeInterval(-600), command: [String] = ["/bin/sh", "-c", "sleep 1"]
    ) -> ContainerConfiguration {
        var configuration = ContainerConfiguration(
            id: id, image: imageDescription(),
            process: ProcessConfiguration(executable: command[0], arguments: Array(command.dropFirst()), environment: ["PATH=/bin"]))
        configuration.labels = labels
        configuration.creationDate = created
        configuration.networks = [AttachmentConfiguration(network: builtin, options: AttachmentOptions(hostname: id))]
        return configuration
    }

    static func attachment(_ network: String = builtin, address: String = "192.168.64.3/24") throws -> Attachment {
        Attachment(
            network: network, hostname: "h", ipv4Address: try CIDRv4(address), ipv4Gateway: try IPv4Address("192.168.64.1"), ipv6Address: nil,
            macAddress: nil)
    }

    static func snapshot(
        _ configuration: ContainerConfiguration, status: RuntimeStatus = .running, started: Date? = now.addingTimeInterval(-300), exitCode: Int32? = nil,
        exited: Date? = nil, incarnation: String = "inc-1", networks: [Attachment] = []
    ) -> ContainerSnapshot {
        ContainerSnapshot(
            configuration: configuration, incarnation: incarnation, status: status, networks: networks, startedDate: started, exitCode: exitCode,
            exitedAt: exited)
    }

    /// A container this service made: labelled with its Docker ID and name.
    static func dockerContainer(
        name: String, dockerID: String, status: RuntimeStatus = .running, created: Date = now.addingTimeInterval(-600), extraLabels: [String: String] = [:],
        exitCode: Int32? = nil, started: Date? = now.addingTimeInterval(-300)
    ) -> ContainerSnapshot {
        var labels = extraLabels
        labels[DockerLabels.id] = dockerID
        labels[DockerLabels.name] = name
        return snapshot(
            configuration(id: String(dockerID.prefix(12)), labels: labels, created: created), status: status, started: started, exitCode: exitCode,
            exited: status == .stopped && started != nil ? now.addingTimeInterval(-60) : nil)
    }

    static func id(_ prefix: String) -> String {
        prefix + String(repeating: "0", count: 64 - prefix.count)
    }
}

/// A persistence that keeps the records in memory, counting saves.
final class MemoryIdentityPersistence: DockerIdentityPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DockerContainerRecord]
    private(set) var saves = 0

    init(_ records: [DockerContainerRecord] = []) {
        stored = records
    }

    func load() throws -> [DockerContainerRecord] {
        lock.withLock { stored }
    }

    func save(_ records: [DockerContainerRecord]) throws {
        lock.withLock {
            stored = records
            saves += 1
        }
    }

    var records: [DockerContainerRecord] { lock.withLock { stored } }
}
