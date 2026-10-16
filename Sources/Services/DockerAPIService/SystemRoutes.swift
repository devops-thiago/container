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

import NIOHTTP1

/// What `/version` and `/info` report about the engine behind the API.
public struct EngineSummary: Sendable, Equatable {
    public var engineVersion: String
    public var engineCommit: String
    public var kernelVersion: String
    public var operatingSystem: String
    public var architecture: String
    public var cpus: Int
    public var memoryBytes: Int64
    public var containers: Int
    public var containersRunning: Int
    public var containersStopped: Int
    public var images: Int
    public var name: String
    public var rootDirectory: String

    public init(
        engineVersion: String, engineCommit: String, kernelVersion: String, operatingSystem: String, architecture: String,
        cpus: Int, memoryBytes: Int64, containers: Int, containersRunning: Int, containersStopped: Int, images: Int,
        name: String, rootDirectory: String
    ) {
        self.engineVersion = engineVersion
        self.engineCommit = engineCommit
        self.kernelVersion = kernelVersion
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.containers = containers
        self.containersRunning = containersRunning
        self.containersStopped = containersStopped
        self.images = images
        self.name = name
        self.rootDirectory = rootDirectory
    }
}

/// The engine as the system routes see it. The agent answers it from the API server; tests
/// answer it from a fake.
public protocol EngineSystem: Sendable {
    func summary() async throws -> EngineSummary
}

/// `_ping`, `/version` and `/info`: what the CLI asks before anything else.
public enum SystemRoutes {
    /// What `_ping`'s `Builder-Version` says. `1` is the classic builder: the CLI then builds
    /// through buildx when it has it, which reaches the builder VM's buildkitd on its own, and
    /// with `DOCKER_BUILDKIT=0` through `POST /build`. `2` would send it to a gRPC session
    /// endpoint this service does not have.
    public static let builderVersion = "1"

    public static func register(on router: inout DockerRouter, engine: some EngineSystem) {
        // HEAD /_ping, which the CLI sends first, is answered by this route without its body.
        router.add(.GET, "/_ping") { _, _ in ping() }
        router.add(.GET, "/version") { _, _ in try .json(VersionBody(try await engine.summary())) }
        router.add(.GET, "/info") { _, _ in try .json(InfoBody(try await engine.summary())) }
    }

    static func ping() -> DockerResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Builder-Version", value: builderVersion)
        headers.add(name: "Swarm", value: "inactive")
        headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        headers.add(name: "Pragma", value: "no-cache")
        return .data(status: .ok, contentType: "text/plain; charset=utf-8", body: .init(string: "OK"), headers: headers)
    }

    struct VersionBody: Encodable {
        struct PlatformBody: Encodable { let Name: String }
        struct ComponentBody: Encodable {
            let Name: String
            let Version: String
            let Details: [String: String]
        }
        let Platform: PlatformBody
        let Components: [ComponentBody]
        let Version: String
        let ApiVersion: String
        let MinAPIVersion: String
        let GitCommit: String
        let GoVersion: String
        let Os: String
        let Arch: String
        let KernelVersion: String

        init(_ engine: EngineSummary) {
            Platform = PlatformBody(Name: "SiliconShip")
            Components = [
                ComponentBody(
                    Name: "Engine", Version: engine.engineVersion,
                    Details: [
                        "ApiVersion": DockerAPIVersion.current.description,
                        "MinAPIVersion": DockerAPIVersion.minimum.description,
                        "GitCommit": engine.engineCommit,
                        "Os": "linux", "Arch": engine.architecture, "KernelVersion": engine.kernelVersion,
                    ])
            ]
            // The engine's own version is the component's, and `Platform` names it.
            Version = DockerAPIVersion.dockerRelease
            ApiVersion = DockerAPIVersion.current.description
            MinAPIVersion = DockerAPIVersion.minimum.description
            GitCommit = engine.engineCommit
            // dockerd reports its Go toolchain; this service has none.
            GoVersion = ""
            Os = "linux"
            Arch = engine.architecture
            KernelVersion = engine.kernelVersion
        }
    }

    struct InfoBody: Encodable {
        let ID: String
        let Containers: Int
        let ContainersRunning: Int
        let ContainersPaused: Int
        let ContainersStopped: Int
        let Images: Int
        let Driver: String
        let OperatingSystem: String
        let OSType: String
        let Architecture: String
        let NCPU: Int
        let MemTotal: Int64
        let Name: String
        let ServerVersion: String
        let KernelVersion: String
        let DockerRootDir: String
        let Labels: [String]
        let ExperimentalBuild: Bool
        let Warnings: [String]

        init(_ engine: EngineSummary) {
            ID = engine.name
            Containers = engine.containers
            ContainersRunning = engine.containersRunning
            ContainersPaused = 0
            ContainersStopped = engine.containersStopped
            Images = engine.images
            Driver = "virtiofs"
            OperatingSystem = engine.operatingSystem
            OSType = "linux"
            Architecture = engine.architecture
            NCPU = engine.cpus
            MemTotal = engine.memoryBytes
            Name = engine.name
            ServerVersion = engine.engineVersion
            KernelVersion = engine.kernelVersion
            DockerRootDir = engine.rootDirectory
            Labels = []
            ExperimentalBuild = false
            Warnings = []
        }
    }
}
