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
import NIOHTTP1

/// `container cp` with `-` for one side, as `docker cp` has it: `CTR:SRC -` writes a tar of SRC
/// to stdout, `- CTR:DEST` reads a tar from stdin into the directory DEST. The archive is the
/// one the Docker API's archive routes serve and take (`ContainerPathArchive`), so the two
/// agree entry for entry.
enum ContainerCopyStream {
    /// Writes `path` in container `id` to `output` as a tar.
    static func copyOut(id: String, path: String, followLink: Bool, to output: FileHandle) async throws {
        let tools = ClientContainerTools()
        let container = try await ContainerClient().get(id: id)
        try await translated {
            try await ContainerPathArchive.write(
                tools, container: container, path: path, reference: id, followLink: followLink, requester: nil, to: output)
        }
    }

    /// Reads a tar from `input` into the directory `path` in container `id`.
    static func copyIn(id: String, path: String, from input: FileHandle) async throws {
        let tools = ClientContainerTools()
        let container = try await ContainerClient().get(id: id)
        try await translated {
            try await ContainerPathArchive.extract(tools, container: container, from: input, into: path, reference: id, requester: nil)
        }
    }

    /// A Docker API error as the CLI reports one: its message alone.
    private static func translated(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as DockerAPIError {
            let code: ContainerizationError.Code =
                switch error.status {
                case .notFound: .notFound
                case .badRequest: .invalidArgument
                default: .internalError
                }
            throw ContainerizationError(code, message: error.message)
        }
    }
}

/// The engine as `ContainerPathArchive` uses it, through the client the other `container`
/// commands use: `stat` and `readlink` run in the container, and the copies stage in the
/// directory the engine and this process can both reach.
struct ClientContainerTools: EngineContainerTools {
    func createProcess(
        _ container: ContainerSnapshot, id: String, configuration: ProcessConfiguration, stdio: DockerProcessStdio
    ) async throws -> any EngineExecProcess {
        ClientExecProcess(
            process: try await ContainerClient().createProcess(containerId: container.id, processId: id, configuration: configuration, stdio: stdio.handles))
    }

    func log(_ container: ContainerSnapshot) async throws -> FileHandle {
        let handles = try await ContainerClient().logs(id: container.id)
        for extra in handles.dropFirst() { try? extra.close() }
        guard let log = handles.first else { throw ContainerizationError(.internalError, message: "the engine returned no log for container \(container.id)") }
        return log
    }

    func stats(_ container: ContainerSnapshot) async throws -> ContainerStats {
        try await ContainerClient().stats(id: container.id)
    }

    func scratchDirectory() throws -> URL {
        try PathUtils.sharedTemporaryDirectory()
    }

    func copyOut(_ container: ContainerSnapshot, source: String, destination: URL, requester: String?) async throws {
        try await ContainerClient().copyOut(id: container.id, source: source, destination: destination.path(percentEncoded: false), requester: requester)
    }

    func copyIn(_ container: ContainerSnapshot, source: URL, destination: String, mode: UInt32, requester: String?) async throws {
        try await ContainerClient().copyIn(
            id: container.id, source: source.path(percentEncoded: false), destination: destination, mode: mode, requester: requester)
    }
}

/// A process `ContainerPathArchive` runs in a container (`stat`, `readlink`).
struct ClientExecProcess: EngineExecProcess {
    let process: any ClientProcess

    func start() async throws { try await process.start() }
    func wait() async throws -> Int32 { try await process.wait() }
    func resize(width: UInt16, height: UInt16) async throws { try await process.resize(Terminal.Size(width: width, height: height)) }
    func kill(_ signal: Int32) async throws { try await process.kill(signal) }
}
