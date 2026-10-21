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

import ContainerAPIClient
import DockerAPIService
import Foundation

/// The engine summary `/version` and `/info` report, read from the API server: what the
/// Docker API agent serves and `container info --format` prints.
public struct EngineSystemClient: EngineSystem {
    public init() {}

    public func summary() async throws -> EngineSummary {
        let health = try await ClientHealthCheck.ping()
        let containers = try await ContainerClient().list()
        let images = try await ClientImage.list()
        let running = containers.filter { $0.status == .running }.count
        return EngineSummary(
            engineVersion: health.apiServerVersion,
            engineCommit: health.apiServerCommit,
            kernelVersion: EngineSummary.kernelVersion,
            operatingSystem: "SiliconShip",
            architecture: EngineSummary.architecture,
            cpus: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            containers: containers.count,
            containersRunning: running,
            containersStopped: containers.count - running,
            images: images.count,
            name: ProcessInfo.processInfo.hostName,
            rootDirectory: health.appRoot.path(percentEncoded: false))
    }
}
