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
import NIOHTTP1

/// `attach`, `wait` and `resize`: the streams `docker run` and `docker start -a` drive.
extension ContainerRoutes.Routes {
    /// `POST /containers/{id}/attach`: an upgraded connection that becomes the container's
    /// stdio when it next starts.
    ///
    /// The engine binds stdio when it bootstraps a process, so an attach made before the start
    /// waits for the start, which bridges it. A running container's stdio is already bound:
    /// an attach to one that asks for no stdin gets its output from the engine's log, from now
    /// on (with `logs`, from the start of the log), until it stops, which is what an IDE's
    /// container console asks for. One that asks for stdin is refused (409), a partial of this
    /// service that `docker attach` users meet. As with `logs`, stdout and stderr arrive
    /// together, as stdout unless only stderr was asked for.
    func attach(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let (container, _) = try await find(reference)
        let options = DockerAttachOptions(stdin: try request.bool("stdin"), stdout: try request.bool("stdout"), stderr: try request.bool("stderr"))
        let follow = try request.bool("stream")
        let replay = try request.bool("logs")
        let multiplexed = !container.snapshot.configuration.initProcess.terminal
        let running = ContainerViewMapper.isRunning(container.snapshot)
        let held = await streams.processes.holds(container.engineID)
        guard follow else {
            // Past output only: the log, when it was asked for, then the end. A container that
            // never ran has none, and the engine has no log for it.
            guard replay, options.stdout || options.stderr, streams.tools != nil, ContainerViewMapper.hasRun(container.snapshot) else {
                return .hijack(multiplexed: multiplexed) { $0.finishWriting() }
            }
            return try await attachToLog(container, options: options, multiplexed: multiplexed, fromStart: true, follow: false)
        }
        if running || held {
            guard !options.stdin, options.stdout || options.stderr, streams.tools != nil else {
                throw DockerAPIError.conflict(Self.runningAttachMessage(reference))
            }
            return try await attachToLog(container, options: options, multiplexed: multiplexed, fromStart: replay, follow: true)
        }
        let attaches = streams.attaches
        let ticket = try await attaches.reserve(engineID: container.engineID, options: options)
        return .hijack(multiplexed: multiplexed) { stream in
            _ = await attaches.park(ticket, stream: stream)
            // Served: the output is already finished. Let go: nothing will come.
            stream.finishWriting()
        }
    }

    /// An attach served from the container's log: from its start or its end, and on while the
    /// container runs when `follow`.
    func attachToLog(
        _ container: DockerContainer, options: DockerAttachOptions, multiplexed: Bool, fromStart: Bool, follow: Bool
    ) async throws -> DockerResponse {
        guard let tools = streams.tools else { throw DockerAPIError.internalError("the engine has no container log to read") }
        let handle = try await tools.log(container.snapshot)
        let engine = self.engine
        let run: ContainerSnapshot?
        let start: DockerLogFile
        let end: UInt64?
        do {
            // Placed on the log within the run it follows, so the next run's log is never sent
            // as this one's.
            (run, start) = try await ContainerSnapshot.startFollowing(
                follow ? container.snapshot : nil, look: { try await engine.get(container.snapshot.id) }
            ) {
                try DockerLogPump.readingLog {
                    var file = try DockerLogFile(fd: handle.fileDescriptor)
                    try file.seek(tail: fromStart ? nil : 0)
                    return file
                }
            }
            end = follow ? nil : try DockerLogPump.readingLog { try start.size() }
        } catch {
            try? handle.close()
            throw error
        }
        let framer = DockerLogFramer(multiplexed: multiplexed, stream: options.stdout ? .stdout : .stderr, timestamps: false)
        let logOptions = streams.logOptions
        return .hijack(multiplexed: multiplexed) { stream in
            defer { try? handle.close() }
            try? await DockerLogPump.run(
                file: start, end: end, framer: framer, options: logOptions,
                // dockerd ends an attach's streams at the exit, as it does a followed log.
                stillRunning: {
                    guard let run else { return false }
                    return (try await engine.get(run.id)).map { $0.isInRun(of: run) } ?? false
                },
                present: { await stream.peerConnected() },
                write: { try await stream.outbound.write($0) })
            await stream.drain()
            stream.finishWriting()
        }
    }

    static func runningAttachMessage(_ reference: String) -> String {
        "cannot attach to container \(reference)'s input: it is already running, and SiliconShip binds a container's stdin when it starts it. "
            + "Attach before it starts (docker run -it, docker start -ai), or attach to its output alone (docker attach --no-stdin)"
    }

    /// `POST /containers/{id}/wait?condition=`: the head at once, the status at the condition.
    ///
    /// The wait is registered before the head goes out: the CLI sends `start` as soon as the
    /// head arrives, and a process that exits at once must still be heard.
    func wait(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let condition = try DockerWaitCondition(query: request.query("condition"))
        let (container, _) = try await find(reference)
        let waits = streams.waits
        let ticket = try await waits.register(engineID: container.engineID, condition: condition, observed: DockerWaitObservation(container.snapshot))
        return .stream(status: .ok, contentType: "application/json") { writer in
            // Nil when the client left (this task is cancelled then) or the service stops.
            guard let response = await waits.response(ticket) else { return }
            try await writer.writeJSON(response)
        }
    }

    /// `POST /containers/{id}/resize?h=&w=`: sizes the terminal of a process this service
    /// started. One it did not start (`container run -it` owns that terminal) is a 404; a
    /// container without a terminal has nothing to size, and gets a 200 as dockerd gives it.
    func resize(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let height = try Self.dimension("h", request)
        let width = try Self.dimension("w", request)
        let (container, _) = try await find(reference)
        let processes = streams.processes
        guard await processes.holds(container.engineID) || ContainerViewMapper.isRunning(container.snapshot) else {
            throw DockerAPIError.conflict("Container \(container.dockerID) is not running")
        }
        guard container.snapshot.configuration.initProcess.terminal else {
            return .empty(.ok)
        }
        guard try await processes.resize(container.engineID, width: width, height: height) else {
            throw DockerAPIError.notFound(
                "cannot resize container \(reference): SiliconShip sizes the terminal only of a container its Docker API started")
        }
        return .empty(.ok)
    }

    static func dimension(_ name: String, _ request: DockerRequest) throws(DockerAPIError) -> UInt16 {
        guard let text = request.query(name), let value = UInt16(text) else {
            throw .badRequest("invalid value for \(name): \(request.query(name) ?? "")")
        }
        return value
    }
}
