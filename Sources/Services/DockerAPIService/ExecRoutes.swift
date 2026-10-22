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
import NIOCore
import NIOHTTP1

/// `{"Id": …}`: what an exec create answers.
public struct DockerIDResponse: Codable, Sendable, Equatable {
    public let Id: String
}

/// `docker exec`: create, start (hijacked or detached), resize and inspect.
extension ContainerToolRoutes.Routes {
    /// dockerd's status for an exec whose process was lost after it started.
    static var failedStartStatus: Int32 { 126 }

    /// The status dockerd gives an exec that could not start, from why: 126 when the command
    /// cannot be invoked, 127 when it is not there, 128 otherwise.
    static func startFailureStatus(_ message: String) -> Int32 {
        let text = message.lowercased()
        if text.contains("permission denied") || text.contains("is a directory") { return 126 }
        let notFound = [
            "not a directory", "executable file not found", "no such file or directory", "failed to find target executable",
        ]
        if notFound.contains(where: text.contains) { return 127 }
        return 128
    }

    /// `POST /containers/{id}/exec`: records the exec; nothing runs until its start.
    func createExec(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let body = try request.decode(DockerExecCreateBody.self)
        guard let command = body.Cmd, !command.isEmpty else { throw DockerAPIError.badRequest("No exec command specified") }
        let container = try await running(reference)
        let id = try await streams.execs.create(try DockerExecSpec.make(body, in: container))
        return try .json(DockerIDResponse(Id: id), status: .created)
    }

    /// `GET /exec/{id}/json`.
    func inspectExec(_ id: String) async throws -> DockerResponse {
        try .json(try await streams.execs.inspect(id))
    }

    /// `POST /exec/{id}/resize?h=&w=`.
    func resizeExec(_ id: String, _ request: DockerRequest) async throws -> DockerResponse {
        let height = try Self.dimension("h", "height", request)
        let width = try Self.dimension("w", "width", request)
        try await streams.execs.resize(id, width: width, height: height)
        return .empty(.ok)
    }

    static func dimension(_ name: String, _ word: String, _ request: DockerRequest) throws(DockerAPIError) -> UInt16 {
        guard let text = request.query(name), let value = UInt16(text) else {
            throw .badRequest("invalid resize \(word) \"\(request.query(name) ?? "")\"")
        }
        return value
    }

    /// `POST /exec/{id}/start`, body `{"Detach":…,"Tty":…}`.
    ///
    /// Attached, the connection is hijacked: raw with a tty, multiplexed without, as the start's
    /// `Tty` says. The process is made, bridged and started inside the hijacked stream, as
    /// dockerd does: a failure from then on is written into the stream, and the exec exits
    /// with dockerd's status for why (127 for a command that is not there). Detached, the process
    /// runs with no stdio and the answer is a 200.
    func startExec(_ id: String, _ request: DockerRequest) async throws -> DockerResponse {
        let options = request.body.readableBytes > 0 ? try request.decode(DockerExecStartBody.self) : DockerExecStartBody()
        let execs = streams.execs
        let spec = try await execs.spec(id)
        guard let snapshot = try await engine.get(spec.engineID) else {
            throw DockerAPIError.notFound("No such container: \(id)")
        }
        guard ContainerViewMapper.isRunning(snapshot) else {
            throw DockerAPIError.conflict("container \(spec.containerID) is not running")
        }
        _ = try await execs.begin(id)
        let consoleSize = spec.process.terminal ? (options.ConsoleSize ?? spec.consoleSize) : nil
        let engine = self.engine

        if options.Detach ?? false {
            do {
                let process = try await engine.createProcess(snapshot, id: id, configuration: spec.process, stdio: .detached)
                try await process.start()
                try? await Self.size(process, await execs.started(id, process: process), consoleSize)
                Task {
                    let code = (try? await process.wait()) ?? Self.failedStartStatus
                    await execs.exited(id, code: code)
                }
            } catch {
                await execs.exited(id, code: Self.startFailureStatus(DockerContainerProcesses.message(error)))
                throw error
            }
            return .empty(.ok)
        }

        let drain = streams.drain
        return .hijack(multiplexed: !(options.Tty ?? false)) { stream in
            await Self.run(id, spec: spec, in: snapshot, engine: engine, execs: execs, stream: stream, consoleSize: consoleSize, drain: drain)
        }
    }

    /// Runs an attached exec on its hijacked connection: pipes for the streams it asked for,
    /// the process made with them and started, and the session that bridges the two until it
    /// exits. The exit is recorded before the stream half-closes.
    static func run(
        _ id: String, spec: DockerExecSpec, in snapshot: ContainerSnapshot, engine: Engine, execs: DockerExecStore, stream: DockerHijackedStream,
        consoleSize: [UInt16]?, drain: Duration
    ) async {
        let attach = DockerParkedAttach(
            ticket: DockerAttachTicket(id: 0, engineID: spec.engineID),
            options: DockerAttachOptions(stdin: spec.attachStdin, stdout: spec.attachStdout, stderr: spec.attachStderr), stream: stream)
        let session: DockerStdioSession
        let process: any EngineExecProcess
        do {
            let stdinPipe = spec.attachStdin ? try StdioPipe(.intoContainer) : nil
            let stdoutPipe = spec.attachStdout ? try StdioPipe(.outOfContainer) : nil
            // A terminal has no separate stderr.
            let stderrPipe = spec.attachStderr && !spec.process.terminal ? try StdioPipe(.outOfContainer) : nil
            let pipes = [stdinPipe, stdoutPipe, stderrPipe].compactMap { $0 }
            do {
                defer { pipes.forEach { $0.closeContainerEnd() } }
                process = try await engine.createProcess(
                    snapshot, id: id, configuration: spec.process,
                    stdio: DockerProcessStdio(
                        stdin: try stdinPipe?.containerHandleForEngine(), stdout: try stdoutPipe?.containerHandleForEngine(),
                        stderr: try stderrPipe?.containerHandleForEngine()))
            }
            session = try await DockerStdioSession.connect(stdin: stdinPipe?.takeHost(), stdout: stdoutPipe?.takeHost(), stderr: stderrPipe?.takeHost())
            do {
                try await process.start()
            } catch {
                await session.close()
                throw error
            }
        } catch {
            let message = DockerContainerProcesses.message(error)
            await execs.exited(id, code: startFailureStatus(message))
            // dockerd writes why on the output, where the client is reading.
            try? await stream.write(ByteBuffer(string: "\(message)\r\n"), stream: .stdout)
            await stream.drain()
            stream.finishWriting()
            return
        }
        try? await size(process, await execs.started(id, process: process), consoleSize)

        let exited = DockerLatch()
        Task {
            let code = (try? await process.wait()) ?? failedStartStatus
            // Before the latch: the session half-closes the stream once it opens, and the
            // client reads the exit code as soon as its output ends.
            await execs.exited(id, code: code)
            exited.open()
        }
        await session.run([attach], exited: exited, drain: drain)
    }

    /// Gives a new process's terminal its first size: one a resize asked for while it was being
    /// made, or the one its start or create gave.
    static func size(_ process: any EngineExecProcess, _ pending: (width: UInt16, height: UInt16)?, _ consoleSize: [UInt16]?) async throws {
        if let pending {
            try await process.resize(width: pending.width, height: pending.height)
        } else if let consoleSize, consoleSize.count == 2, consoleSize[0] > 0, consoleSize[1] > 0 {
            try await process.resize(width: consoleSize[1], height: consoleSize[0])
        }
    }
}
