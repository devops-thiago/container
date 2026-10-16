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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOS
import DockerAPIService
import Foundation

/// The exec, logs, stats, top and archive routes' engine: the API server, through the client
/// the `container exec`, `logs`, `stats` and `copy` commands use.
extension EngineContainersClient: EngineContainerTools {
    func createProcess(
        _ container: ContainerSnapshot, id: String, configuration: ProcessConfiguration, stdio: DockerProcessStdio
    ) async throws -> any EngineExecProcess {
        try await Self.translatedTool {
            EngineExecProcessClient(
                process: try await ContainerClient().createProcess(containerId: container.id, processId: id, configuration: configuration, stdio: stdio.handles))
        }
    }

    func log(_ container: ContainerSnapshot) async throws -> FileHandle {
        let handles = try await Self.translatedTool { try await ContainerClient().logs(id: container.id) }
        // The second is the boot log, which Docker has no place for.
        for extra in handles.dropFirst() { try? extra.close() }
        guard let log = handles.first else { throw DockerAPIError.internalError("the engine returned no log for container \(container.id)") }
        return log
    }

    func stats(_ container: ContainerSnapshot) async throws -> ContainerStats {
        try await Self.translatedTool { try await ContainerClient().stats(id: container.id) }
    }

    func scratchDirectory() throws -> URL {
        // Both this agent and the engine's helpers can reach it, sandboxed or not.
        try PathUtils.sharedTemporaryDirectory()
    }

    func copyOut(_ container: ContainerSnapshot, source: String, destination: URL, requester: String?) async throws {
        try await Self.translatedTool {
            try await ContainerClient().copyOut(
                id: container.id, source: source, destination: destination.path(percentEncoded: false), requester: requester)
        }
    }

    func copyIn(_ container: ContainerSnapshot, source: URL, destination: String, mode: UInt32, requester: String?) async throws {
        try await Self.translatedTool {
            try await ContainerClient().copyIn(
                id: container.id, source: source.path(percentEncoded: false), destination: destination, mode: mode, requester: requester)
        }
    }

    /// The engine's errors as a Docker client should see them. The process and copy calls wrap
    /// what went wrong as their cause, so the message names it.
    private static func translatedTool<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ContainerizationError {
            let message = error.cause.map { "\(error.message): \($0)" } ?? error.message
            switch error.code {
            case .notFound: throw DockerAPIError.notFound(message)
            case .exists, .invalidState: throw DockerAPIError.conflict(message)
            case .invalidArgument, .unsupported: throw DockerAPIError.badRequest(message)
            default: throw DockerAPIError.internalError(message)
            }
        }
    }
}

/// An exec, or a command the agent runs for itself, through the client `container exec` uses.
struct EngineExecProcessClient: EngineExecProcess {
    let process: any ClientProcess

    func start() async throws {
        try await process.start()
    }

    func wait() async throws -> Int32 {
        try await process.wait()
    }

    func resize(width: UInt16, height: UInt16) async throws {
        try await process.resize(Terminal.Size(width: width, height: height))
    }

    func kill(_ signal: Int32) async throws {
        try await process.kill(signal)
    }
}
