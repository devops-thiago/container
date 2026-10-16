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

/// `POST /containers/{id}/exec`'s body. `DetachKeys` is read and ignored: the bytes reach the
/// process as they are.
public struct DockerExecCreateBody: Decodable, Sendable {
    public var AttachStdin: Bool?
    public var AttachStdout: Bool?
    public var AttachStderr: Bool?
    public var DetachKeys: String?
    public var Tty: Bool?
    public var Cmd: [String]?
    public var Env: [String]?
    public var WorkingDir: String?
    public var User: String?
    public var Privileged: Bool?
    /// `[height, width]`, for a process with a terminal.
    public var ConsoleSize: [UInt16]?
}

/// `POST /exec/{id}/start`'s body.
public struct DockerExecStartBody: Decodable, Sendable {
    public var Detach: Bool?
    public var Tty: Bool?
    public var ConsoleSize: [UInt16]?
}

/// `GET /exec/{id}/json`.
public struct DockerExecInspect: Encodable, Sendable, Equatable {
    public struct ExecProcessConfig: Encodable, Sendable, Equatable {
        public let tty: Bool
        public let entrypoint: String
        public let arguments: [String]
        public let privileged: Bool
        public let user: String
    }

    public let ID: String
    public let Running: Bool
    /// Null until the process has exited, as dockerd has it.
    public let ExitCode: Int?
    public let ProcessConfig: ExecProcessConfig
    public let OpenStdin: Bool
    public let OpenStderr: Bool
    public let OpenStdout: Bool
    public let CanRemove: Bool
    public let ContainerID: String
    public let DetachKeys: String
    /// The process's PID in the container, which the engine does not report: always 0.
    public let Pid: Int

    enum CodingKeys: String, CodingKey {
        case ID, Running, ExitCode, ProcessConfig, OpenStdin, OpenStderr, OpenStdout, CanRemove, ContainerID, DetachKeys, Pid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ID, forKey: .ID)
        try container.encode(Running, forKey: .Running)
        // `null`, not absent: the CLI tells "still running" from "exited 0" by it.
        try container.encode(ExitCode, forKey: .ExitCode)
        try container.encode(ProcessConfig, forKey: .ProcessConfig)
        try container.encode(OpenStdin, forKey: .OpenStdin)
        try container.encode(OpenStderr, forKey: .OpenStderr)
        try container.encode(OpenStdout, forKey: .OpenStdout)
        try container.encode(CanRemove, forKey: .CanRemove)
        try container.encode(ContainerID, forKey: .ContainerID)
        try container.encode(DetachKeys, forKey: .DetachKeys)
        try container.encode(Pid, forKey: .Pid)
    }
}

/// An exec as it was created: what it runs, how, and which streams it takes.
public struct DockerExecSpec: Sendable {
    public let engineID: String
    /// The container's Docker ID, which `ContainerID` reports.
    public let containerID: String
    /// What the engine runs: the container's init process with the exec's command, environment,
    /// directory, user and terminal.
    public let process: ProcessConfiguration
    public let attachStdin: Bool
    public let attachStdout: Bool
    public let attachStderr: Bool
    public let privileged: Bool
    /// The user the client asked for; empty for the container's own.
    public let user: String
    /// `[height, width]` from the create, used when the start gives none.
    public let consoleSize: [UInt16]?

    public init(
        engineID: String, containerID: String, process: ProcessConfiguration, attachStdin: Bool, attachStdout: Bool, attachStderr: Bool,
        privileged: Bool = false, user: String = "", consoleSize: [UInt16]? = nil
    ) {
        self.engineID = engineID
        self.containerID = containerID
        self.process = process
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.privileged = privileged
        self.user = user
        self.consoleSize = consoleSize
    }

    /// The exec a create body asks for in `container`, built the way dockerd builds one: the
    /// command replaces the container's, the environment is the container's with the exec's
    /// variables replacing or added, and an empty directory or user is the container's.
    public static func make(_ body: DockerExecCreateBody, in container: DockerContainer) throws(DockerAPIError) -> DockerExecSpec {
        guard let command = body.Cmd, let executable = command.first else {
            throw .badRequest("No exec command specified")
        }
        var process = container.snapshot.configuration.initProcess
        process.executable = executable
        process.arguments = Array(command.dropFirst())
        process.environment = Self.merge(process.environment, body.Env ?? [])
        if let directory = body.WorkingDir, !directory.isEmpty {
            process.workingDirectory = directory
        }
        let tty = body.Tty ?? false
        process.terminal = tty
        let user = body.User ?? ""
        if !user.isEmpty {
            process.user = .raw(userString: user)
            process.supplementalGroups = []
        }
        return DockerExecSpec(
            engineID: container.engineID, containerID: container.dockerID, process: process, attachStdin: body.AttachStdin ?? false,
            attachStdout: body.AttachStdout ?? false, attachStderr: body.AttachStderr ?? false, privileged: body.Privileged ?? false,
            user: user, consoleSize: tty ? body.ConsoleSize : nil)
    }

    /// `base` with each of `overrides` replacing the variable of the same name, or added after
    /// them when there is none.
    static func merge(_ base: [String], _ overrides: [String]) -> [String] {
        func name(_ entry: String) -> Substring { entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0] }
        var merged = base
        for entry in overrides {
            if let index = merged.firstIndex(where: { name($0) == name(entry) }) {
                merged[index] = entry
            } else {
                merged.append(entry)
            }
        }
        return merged
    }
}

/// How much the exec store holds.
public struct DockerExecLimits: Sendable {
    /// Execs held at once.
    public var total: Int
    /// Execs held for one container.
    public var perContainer: Int
    /// How long an exec that was never started is kept.
    public var unstartedLifetime: Duration
    /// How long an exec that has exited is kept, for the client to read its exit code.
    public var exitedLifetime: Duration
    /// How long a resize waits for its exec's process to start.
    public var resizeWait: Duration

    public init(
        total: Int = 256, perContainer: Int = 64, unstartedLifetime: Duration = .seconds(600), exitedLifetime: Duration = .seconds(300),
        resizeWait: Duration = .seconds(10)
    ) {
        self.total = total
        self.perContainer = perContainer
        self.unstartedLifetime = unstartedLifetime
        self.exitedLifetime = exitedLifetime
        self.resizeWait = resizeWait
    }
}

/// The execs clients created, until they have run and their exit has been read.
///
/// An exec is made by its create and runs at most once, at its start. It is kept while it
/// runs; one never started and one that has exited are forgotten after a while, so the store
/// stays bounded however many execs clients make and abandon. Exits are recorded here before
/// the client's stream ends, so a client that reads `ExitCode` as soon as its output ends sees
/// the real one.
public actor DockerExecStore {
    enum Phase: Sendable, Equatable {
        case created
        case starting
        case running
        case exited(Int32)
    }

    private struct Record {
        let id: String
        let spec: DockerExecSpec
        var phase: Phase = .created
        var process: (any EngineExecProcess)?
        /// A size asked for before the process was there to take it.
        var pendingSize: (width: UInt16, height: UInt16)?
        /// Open once the start has made the process or failed to.
        let settled = DockerLatch()
        var since: ContinuousClock.Instant
    }

    private var records: [String: Record] = [:]
    private var stopped = false
    public let limits: DockerExecLimits
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(limits: DockerExecLimits = .init(), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.limits = limits
        self.now = now
    }

    /// Execs held.
    public var count: Int {
        expire()
        return records.count
    }

    /// Records an exec and returns its ID.
    public func create(_ spec: DockerExecSpec) throws(DockerAPIError) -> String {
        guard !stopped else { throw DockerAPIError(.serviceUnavailable, "the Docker API service is stopping") }
        expire()
        guard records.values.filter({ $0.spec.engineID == spec.engineID }).count < limits.perContainer else {
            throw DockerAPIError(.tooManyRequests, "container \(spec.containerID) already has \(limits.perContainer) execs")
        }
        guard records.count < limits.total else {
            throw DockerAPIError(.tooManyRequests, "too many execs are held")
        }
        var generator = SystemRandomNumberGenerator()
        var id = DockerIdentityTable.randomID(using: &generator)
        while records[id] != nil {
            id = DockerIdentityTable.randomID(using: &generator)
        }
        records[id] = Record(id: id, spec: spec, since: now())
        return id
    }

    /// The exec `id` as it was created.
    public func spec(_ id: String) throws(DockerAPIError) -> DockerExecSpec {
        try record(id).spec
    }

    public func inspect(_ id: String) throws(DockerAPIError) -> DockerExecInspect {
        let record = try record(id)
        let exitCode: Int?
        if case .exited(let code) = record.phase { exitCode = Int(code) } else { exitCode = nil }
        let running = record.phase == .running || record.phase == .starting
        return DockerExecInspect(
            ID: record.id, Running: running, ExitCode: exitCode,
            ProcessConfig: .init(
                tty: record.spec.process.terminal, entrypoint: record.spec.process.executable, arguments: record.spec.process.arguments,
                privileged: record.spec.privileged, user: record.spec.user),
            OpenStdin: record.spec.attachStdin, OpenStderr: record.spec.attachStderr, OpenStdout: record.spec.attachStdout,
            CanRemove: false, ContainerID: record.spec.containerID, DetachKeys: "", Pid: 0)
    }

    /// Claims the exec for a start. An exec runs once: one already running or already run is
    /// refused as dockerd refuses it.
    public func begin(_ id: String) throws(DockerAPIError) -> DockerExecSpec {
        var record = try record(id)
        switch record.phase {
        case .created:
            break
        case .starting, .running:
            throw .conflict("exec command \(id) is already running")
        case .exited:
            throw .conflict("exec command \(id) has already run")
        }
        record.phase = .starting
        records[id] = record
        return record.spec
    }

    /// The start made and started the process. Returns the size to give its terminal: one a
    /// resize asked for before now, or nil.
    public func started(_ id: String, process: any EngineExecProcess) -> (width: UInt16, height: UInt16)? {
        guard var record = records[id] else { return nil }
        record.phase = .running
        record.process = process
        let size = record.pendingSize
        record.pendingSize = nil
        records[id] = record
        record.settled.open()
        return size
    }

    /// The process exited with `code`, or never ran (dockerd's 126 then).
    public func exited(_ id: String, code: Int32) {
        guard var record = records[id] else { return }
        record.phase = .exited(code)
        record.process = nil
        record.since = now()
        records[id] = record
        record.settled.open()
    }

    /// Sizes the exec's terminal. A resize that arrives while the start is still making the
    /// process waits for it, as dockerd waits: the CLI sends its first resize as soon as the
    /// start's `101` is back.
    public func resize(_ id: String, width: UInt16, height: UInt16) async throws {
        let first = try record(id)
        switch first.phase {
        case .created, .starting:
            // Kept for the start, which applies it once the process is there.
            records[id]?.pendingSize = (width, height)
            guard await first.settled.wait(timeout: limits.resizeWait) else {
                throw DockerAPIError.internalError("timeout waiting for exec session ready")
            }
            guard let current = records[id] else { throw DockerAPIError.notFound("No such exec instance: \(id)") }
            // The start took it.
            guard current.pendingSize != nil else { return }
            records[id]?.pendingSize = nil
            throw DockerAPIError.badRequest("exec process is not started")
        case .running:
            guard let process = first.process else { throw DockerAPIError.badRequest("exec process is not started") }
            try await process.resize(width: width, height: height)
        case .exited:
            // A size that arrives after the exit has nothing to size; the CLI sends one when
            // the window changes, whenever that is.
            return
        }
    }

    /// Forgets the execs of a deleted container that are not running.
    public func release(engineID: String) {
        for (id, record) in records where record.spec.engineID == engineID && record.phase != .running && record.phase != .starting {
            records[id] = nil
            record.settled.open()
        }
    }

    /// Refuses new execs and forgets the ones not running.
    public func shutdown() {
        stopped = true
        for (id, record) in records where record.phase != .running && record.phase != .starting {
            records[id] = nil
            record.settled.open()
        }
    }

    private func record(_ id: String) throws(DockerAPIError) -> Record {
        expire()
        guard let record = records[id] else { throw .notFound("No such exec instance: \(id)") }
        return record
    }

    /// Forgets execs never started or long exited.
    private func expire() {
        let now = self.now()
        for (id, record) in records {
            let lifetime: Duration
            switch record.phase {
            case .created: lifetime = limits.unstartedLifetime
            case .exited: lifetime = limits.exitedLifetime
            case .starting, .running: continue
            }
            if record.since.duration(to: now) >= lifetime {
                records[id] = nil
                record.settled.open()
            }
        }
    }
}
