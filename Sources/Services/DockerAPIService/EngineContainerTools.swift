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
import Darwin
import Foundation
import NIOCore
import Synchronization

/// A process this service made inside a running container: an exec, or a command it runs for
/// itself (`ps` for `top`, `stat` for an archive's path).
public protocol EngineExecProcess: EngineProcess {
    /// Sends `signal` to the process.
    func kill(_ signal: Int32) async throws
}

/// What the exec, logs, stats, top and archive routes need from the engine beyond the
/// container routes' own. The agent answers it with the clients the `container` commands use;
/// tests answer it with a fake.
public protocol EngineContainerTools: Sendable {
    /// Makes a process in a running container with `stdio`, ready to start. The engine holds
    /// its own copies of the descriptors once this returns.
    func createProcess(
        _ container: ContainerSnapshot, id: String, configuration: ProcessConfiguration, stdio: DockerProcessStdio
    ) async throws -> any EngineExecProcess
    /// The container's log: what its init process wrote to stdout and stderr, together in one
    /// bounded file, without stream tags or times. The caller closes it.
    func log(_ container: ContainerSnapshot) async throws -> FileHandle
    /// One sample of the container's resource use.
    func stats(_ container: ContainerSnapshot) async throws -> ContainerStats
    /// A directory both this service and the engine can reach, for the copies an archive
    /// route stages.
    func scratchDirectory() throws -> URL
    /// Copies `source` in the container to `destination` on the host: a file, or a directory
    /// and everything in it. `requester` is as `EngineContainers.create` takes it.
    func copyOut(_ container: ContainerSnapshot, source: String, destination: URL, requester: String?) async throws
    /// Copies `source` on the host into the directory `destination` in the container, as
    /// `destination/<name of source>`. A file gets `mode`. `requester` is as
    /// `EngineContainers.create` takes it.
    func copyIn(_ container: ContainerSnapshot, source: URL, destination: String, mode: UInt32, requester: String?) async throws
}

/// What a command this service ran in a container left behind.
struct DockerCapturedRun: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// Output past the capture limit was read and dropped.
    let truncated: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

    /// The first line of stderr, which is where a command says why it failed.
    var reason: String {
        String(decoding: stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}

/// Runs a command in a container and captures its output, for what this service asks of a
/// container itself (`ps`, `stat`, `readlink`).
enum DockerContainerCommand {
    /// The command could not be run at all: the engine refused to make or start it.
    struct Unavailable: Error, Sendable {
        let message: String
    }

    /// A shell's status for a command it cannot find, which is also what a missing executable
    /// exits with in a container.
    static let notFoundStatus: Int32 = 127

    /// Runs `arguments` as root in `/` with the container's environment (its `PATH` finds the
    /// command), without stdin. At most `limit` bytes of each stream are kept; the rest is
    /// read and dropped, so a chatty command never blocks on a full pipe. A command still
    /// running after `timeout` is killed.
    static func run(
        _ tools: some EngineContainerTools, in container: ContainerSnapshot, _ arguments: [String], limit: Int = 1 << 20,
        timeout: Duration = .seconds(10)
    ) async throws -> DockerCapturedRun {
        guard let executable = arguments.first else { throw DockerAPIError.internalError("no command to run") }
        var configuration = container.configuration.initProcess
        configuration.executable = executable
        configuration.arguments = Array(arguments.dropFirst())
        configuration.terminal = false
        configuration.workingDirectory = "/"
        configuration.user = .id(uid: 0, gid: 0)
        configuration.supplementalGroups = []

        let stdoutPipe = try StdioPipe(.outOfContainer)
        let stderrPipe = try StdioPipe(.outOfContainer)
        let process: any EngineExecProcess
        do {
            defer {
                stdoutPipe.closeContainerEnd()
                stderrPipe.closeContainerEnd()
            }
            process = try await tools.createProcess(
                container, id: "docker-api-\(UUID().uuidString.lowercased())", configuration: configuration,
                stdio: DockerProcessStdio(stdout: stdoutPipe.containerHandle, stderr: stderrPipe.containerHandle))
        } catch {
            throw Unavailable(message: DockerContainerProcesses.message(error))
        }
        let session = try await DockerStdioSession.connect(stdin: nil, stdout: stdoutPipe.takeHost(), stderr: stderrPipe.takeHost())
        do {
            try await process.start()
        } catch {
            await session.close()
            throw Unavailable(message: DockerContainerProcesses.message(error))
        }

        let out = Capture(limit: limit)
        let err = Capture(limit: limit)
        let readers = Task {
            await withTaskGroup(of: Void.self) { group in
                if let stdout = session.stdout { group.addTask { await Self.read(stdout, into: out) } }
                if let stderr = session.stderr { group.addTask { await Self.read(stderr, into: err) } }
            }
        }
        let status: Int32
        do {
            status = try await Self.waitForExit(process, timeout: timeout)
        } catch {
            readers.cancel()
            await readers.value
            throw error
        }
        // Whatever the command wrote is in the pipes by now; something it left behind may
        // still hold them open, which a moment's wait does not outlast.
        let drained = Task {
            try? await Task.sleep(for: .seconds(2))
            readers.cancel()
        }
        await readers.value
        drained.cancel()
        return DockerCapturedRun(status: status, stdout: out.data, stderr: err.data, truncated: out.truncated || err.truncated)
    }

    private static func waitForExit(_ process: any EngineExecProcess, timeout: Duration) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask { try await process.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DockerAPIError.internalError("the command did not run") }
            if let status = first { return status }
            try? await process.kill(SIGKILL)
            throw DockerAPIError.internalError("the command did not finish within \(timeout)")
        }
    }

    private static func read(_ pipe: DockerStdioSession.Pipe, into capture: Capture) async {
        try? await pipe.executeThenClose { inbound, _ in
            for try await chunk in inbound {
                capture.append(chunk)
            }
        }
    }

    /// Output kept up to a limit.
    final class Capture: Sendable {
        private struct State {
            var data = Data()
            var truncated = false
        }

        private let limit: Int
        private let state = Mutex(State())

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: ByteBuffer) {
            state.withLock { state in
                let room = limit - state.data.count
                if chunk.readableBytes > room { state.truncated = true }
                guard room > 0 else { return }
                state.data.append(contentsOf: chunk.readableBytesView.prefix(room))
            }
        }

        var data: Data { state.withLock { $0.data } }
        var truncated: Bool { state.withLock { $0.truncated } }
    }
}
