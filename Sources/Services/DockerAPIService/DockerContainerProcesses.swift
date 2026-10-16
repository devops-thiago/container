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

import Logging

/// The processes this service started, and what their starts bound.
///
/// A start takes the attaches waiting for the container, makes pipes for the streams they
/// asked for (with a tty, stdout only: a terminal has no separate stderr), bootstraps the
/// process with them and starts it. Without attaches it binds nothing, as a detached
/// `container run -d` does. Either way the process is kept: its exit status is what `wait`
/// answers with, and its terminal is what `resize` sizes.
public actor DockerContainerProcesses {
    public enum StartOutcome: Sendable, Equatable {
        case started
        /// Already running, or being started by another request.
        case alreadyRunning
    }

    private struct Running {
        let epoch: UInt64
        let process: any EngineProcess
        let exited: DockerLatch
    }

    private var running: [String: Running] = [:]
    private var starting: Set<String> = []
    private var epoch: UInt64 = 0
    private let engine: any EngineContainers
    private let attaches: DockerAttachStore
    private let waits: DockerWaitStore
    private let drain: Duration
    private let log: Logger

    init(engine: any EngineContainers, attaches: DockerAttachStore, waits: DockerWaitStore, drain: Duration, log: Logger) {
        self.engine = engine
        self.attaches = attaches
        self.waits = waits
        self.drain = drain
        self.log = log
    }

    /// Whether a process this service started is running in `engineID`.
    public func holds(_ engineID: String) -> Bool {
        running[engineID].map { !$0.exited.isOpen } ?? false
    }

    /// Starts `container`'s init process, bridged to the attaches waiting for it.
    public func start(_ container: DockerContainer) async throws -> StartOutcome {
        let engineID = container.engineID
        guard !starting.contains(engineID) else { return .alreadyRunning }
        if let current = running[engineID], await !current.exited.wait(timeout: .seconds(5)) {
            // The route saw it stopped, but the process this service started has not exited.
            return .alreadyRunning
        }
        guard !starting.contains(engineID) else { return .alreadyRunning }
        starting.insert(engineID)
        defer { starting.remove(engineID) }

        let claimed = await attaches.claim(engineID: engineID)
        let tickets = claimed.map(\.ticket)
        let tty = container.snapshot.configuration.initProcess.terminal
        // dockerd gives an attach stdin only when the container was made with it open.
        let stdinOpen = container.extras?.openStdin ?? true
        let stdinPipe: StdioPipe?
        let stdoutPipe: StdioPipe?
        let stderrPipe: StdioPipe?
        do {
            stdinPipe = stdinOpen && claimed.contains { $0.options.stdin } ? try StdioPipe(.intoContainer) : nil
            stdoutPipe = claimed.contains { $0.options.stdout } ? try StdioPipe(.outOfContainer) : nil
            stderrPipe = !tty && claimed.contains { $0.options.stderr } ? try StdioPipe(.outOfContainer) : nil
        } catch {
            await attaches.complete(tickets, .released)
            throw DockerAPIError.internalError("could not make the container's stdio: \(error)")
        }
        let pipes = [stdinPipe, stdoutPipe, stderrPipe].compactMap { $0 }
        let stdio = DockerProcessStdio(stdin: stdinPipe?.containerHandle, stdout: stdoutPipe?.containerHandle, stderr: stderrPipe?.containerHandle)

        // Before the process can exit: a wait from here on hears this run's exit.
        await waits.starting(engineID)
        var bootstrapped: (any EngineProcess)?
        var session: DockerStdioSession?
        do {
            defer {
                // The engine holds its own copies once bootstrap returns; until these go, the
                // agent's ends never see EOF.
                pipes.forEach { $0.closeContainerEnd() }
            }
            bootstrapped = try await engine.bootstrap(container.snapshot, stdio: stdio)
            if !claimed.isEmpty {
                session = try await DockerStdioSession.connect(stdin: stdinPipe?.takeHost(), stdout: stdoutPipe?.takeHost(), stderr: stderrPipe?.takeHost())
            }
            try await bootstrapped?.start()
        } catch {
            await session?.close()
            if bootstrapped != nil {
                // What a failed start leaves half-made would get in the way of the next one.
                try? await engine.stop(container.snapshot, timeout: 1, signal: nil)
            }
            await waits.startFailed(engineID, message: Self.message(error))
            await attaches.complete(tickets, .released)
            throw error
        }
        guard let process = bootstrapped else { throw DockerAPIError.internalError("the container's process was not bootstrapped") }

        epoch += 1
        let current = Running(epoch: epoch, process: process, exited: DockerLatch())
        running[engineID] = current
        let waits = self.waits
        let log = self.log
        Task {
            do {
                let code = try await process.wait()
                await waits.exited(engineID, code: code)
            } catch {
                log.warning("lost the process to wait on; following the container instead", metadata: ["container": "\(engineID)", "error": "\(error)"])
                await waits.lost(engineID)
            }
            current.exited.open()
            self.reap(engineID, epoch: current.epoch)
        }
        if let session {
            let attaches = self.attaches
            let drain = self.drain
            // Its own task: the start request ends with its 204, the attaches go on.
            Task {
                await session.run(claimed, exited: current.exited, drain: drain)
                await attaches.complete(tickets, .served)
            }
        }
        return .started
    }

    /// Sizes the terminal of the process this service started in `engineID`. Returns false
    /// when it holds no such process.
    public func resize(_ engineID: String, width: UInt16, height: UInt16) async throws -> Bool {
        guard let current = running[engineID], !current.exited.isOpen else { return false }
        try await current.process.resize(width: width, height: height)
        return true
    }

    private func reap(_ engineID: String, epoch: UInt64) {
        if running[engineID]?.epoch == epoch {
            running[engineID] = nil
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? DockerAPIError)?.message ?? "\(error)"
    }
}

/// The state the stream routes share: attaches waiting for a start, waits, and the processes
/// this service started.
public struct DockerContainerStreams: Sendable {
    public let attaches: DockerAttachStore
    public let waits: DockerWaitStore
    public let processes: DockerContainerProcesses

    /// - Parameter drain: how long an output pipe may stay quiet without reaching EOF after its
    ///   process exited before it is no longer read.
    public init(
        engine: some EngineContainers, attachLimits: DockerAttachLimits = .init(), waitLimits: DockerWaitLimits = .init(),
        drain: Duration = .seconds(3), log: Logger = Logger(label: "DockerAPIService")
    ) {
        let attaches = DockerAttachStore(limits: attachLimits)
        let waits = DockerWaitStore(limits: waitLimits) { engineID in
            try await engine.get(engineID).map(DockerWaitObservation.init)
        }
        self.attaches = attaches
        self.waits = waits
        self.processes = DockerContainerProcesses(engine: engine, attaches: attaches, waits: waits, drain: drain, log: log)
    }

    /// Lets go of everything waiting: attaches end, waits end with no answer.
    public func shutdown() async {
        await attaches.shutdown()
        await waits.shutdown()
    }
}
