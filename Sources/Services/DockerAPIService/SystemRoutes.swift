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
    /// The architecture reported: every container runs in an arm64 VM.
    public static let architecture = "aarch64"
    /// Each container boots its own VM; there is no one kernel to name.
    public static let kernelVersion = ""

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

    /// `/version`'s body, which `container version --format` also prints as `Server`.
    public struct VersionBody: Encodable, Sendable {
        /// The component that carries the engine's own version.
        static let engineComponent = "SiliconShip Engine"

        public struct PlatformBody: Encodable, Sendable { public let Name: String }
        public struct ComponentBody: Encodable, Sendable {
            public let Name: String
            public let Version: String
            public let Details: [String: String]
        }
        public let Platform: PlatformBody
        public let Components: [ComponentBody]
        public let Version: String
        public let ApiVersion: String
        public let MinAPIVersion: String
        public let GitCommit: String
        public let GoVersion: String
        public let Os: String
        public let Arch: String
        public let KernelVersion: String

        init(_ engine: EngineSummary) {
            self.init(
                engineVersion: engine.engineVersion, engineCommit: engine.engineCommit, architecture: engine.architecture,
                kernelVersion: engine.kernelVersion)
        }

        /// What `/version` reports for an engine at `engineVersion`: only the versions, not
        /// the counts `/info` needs.
        public init(
            engineVersion: String, engineCommit: String, architecture: String = EngineSummary.architecture,
            kernelVersion: String = EngineSummary.kernelVersion
        ) {
            let engine = (engineVersion: engineVersion, engineCommit: engineCommit, architecture: architecture, kernelVersion: kernelVersion)
            Platform = PlatformBody(Name: "SiliconShip")
            // `Engine` is dockerd's component, at the server's Version as dockerd has it; the
            // engine's own version is a component of its own, which Docker clients list as
            // they list containerd's.
            Components = [
                ComponentBody(
                    Name: "Engine", Version: DockerAPIVersion.dockerRelease,
                    Details: [
                        "ApiVersion": DockerAPIVersion.current.description,
                        "MinAPIVersion": DockerAPIVersion.minimum.description,
                        "GitCommit": engine.engineCommit,
                        "Os": "linux", "Arch": engine.architecture, "KernelVersion": engine.kernelVersion,
                    ]),
                ComponentBody(Name: Self.engineComponent, Version: engine.engineVersion, Details: ["GitCommit": engine.engineCommit]),
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

    /// `/info`'s body, which `container info --format` also prints.
    public struct InfoBody: Encodable, Sendable {
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

        public init(_ engine: EngineSummary) {
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
            // As dockerd's: the same as `/version`'s Version.
            ServerVersion = DockerAPIVersion.dockerRelease
            KernelVersion = engine.kernelVersion
            DockerRootDir = engine.rootDirectory
            Labels = []
            ExperimentalBuild = false
            Warnings = []
        }
    }
}
