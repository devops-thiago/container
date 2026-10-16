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
import Testing

@testable import DockerAPIService

/// A fake exec process: a `FakeProcess` that can also be killed.
struct FakeExecProcess: EngineExecProcess {
    let process: FakeProcess

    func start() async throws { try await process.start() }
    func wait() async throws -> Int32 { try await process.wait() }
    func resize(width: UInt16, height: UInt16) async throws { try await process.resize(width: width, height: height) }
    func kill(_ signal: Int32) async throws { _ = await process.exit(128 + signal) }
}

/// An engine for the tool routes: the container routes' `FakeEngine`, plus a container
/// filesystem kept in a directory on the host, a log file, stats samples and the commands the
/// routes run inside a container (`stat`, `readlink`, `ps`).
final class FakeTools: EngineContainers, EngineContainerTools, @unchecked Sendable {
    let base: FakeEngine
    /// The container's `/`.
    let root: URL
    let scratch: URL
    let logFile: URL
    private let lock = NSLock()
    /// Executables the container has; a start of anything else fails as the engine's does.
    var available: Set<String> = ["sh", "cat", "stat", "readlink", "ps"]
    /// What `ps` prints.
    var psOutput = "PID   USER     TIME  COMMAND\n    1 root      0:00 sleep 60\n   12 root      0:00 ps -ef\n"
    var psStatus: Int32 = 0
    /// What an exec of anything but the built-in commands runs.
    var program: @Sendable (ProcessConfiguration) -> FakeProgram = { _ in FakePrograms.echo(0) }
    var samples: [ContainerStats] = []
    private var sampleIndex = 0
    private(set) var configurations: [ProcessConfiguration] = []
    private(set) var processes: [String: FakeProcess] = [:]
    private(set) var copies: [String] = []
    /// Who each copy was for, as `"out <requester>"` or `"in <requester>"`, with `-` for none.
    private(set) var copyRequesters: [String] = []
    private var statsCalls = 0
    private var getCalls = 0
    var createError: (any Error)?
    /// Whether the engine copies into a container before its start.
    var copyBeforeStart = false
    /// What a copy in throws, once.
    var copyInError: (any Error)?
    /// The container's status at each copy in, in order.
    private(set) var copyInStatuses: [RuntimeStatus?] = []

    init(snapshots: [ContainerSnapshot]) throws {
        base = FakeEngine(snapshots: snapshots)
        let top = FileManager.default.temporaryDirectory.appending(path: "dapi-tools-\(UUID().uuidString.prefix(8))")
        root = top.appending(path: "root")
        scratch = top.appending(path: "scratch")
        logFile = top.appending(path: "log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: Data())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func with<T>(_ body: (FakeTools) -> T) -> T {
        lock.withLock { body(self) }
    }

    func appendLog(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func process(_ id: String) -> FakeProcess? {
        lock.withLock { processes[id] }
    }

    var lastConfiguration: ProcessConfiguration? { lock.withLock { configurations.last } }
    /// How often the stats and the container were asked for: what a stream that is still
    /// going keeps doing.
    var statsCount: Int { lock.withLock { statsCalls } }
    var getCount: Int { lock.withLock { getCalls } }
    var copyCalls: [String] { lock.withLock { copies } }
    var copyRequesterCalls: [String] { lock.withLock { copyRequesters } }

    // MARK: EngineContainers

    func list() async throws -> [ContainerSnapshot] { try await base.list() }
    func builtinNetwork() async throws -> String? { try await base.builtinNetwork() }
    func image(_ reference: String, platform: String?) async throws -> DockerImageDefaults? { try await base.image(reference, platform: platform) }
    func createDefaults() async throws -> DockerCreateDefaults { try await base.createDefaults() }
    func allocatePort() throws -> UInt16 { try base.allocatePort() }
    func create(_ plan: DockerCreatePlan, requester: String?) async throws -> String { try await base.create(plan, requester: requester) }
    func bootstrap(_ container: ContainerSnapshot, stdio: DockerProcessStdio, requester: String?) async throws -> any EngineProcess {
        try await base.bootstrap(container, stdio: stdio, requester: requester)
    }
    func get(_ engineID: String) async throws -> ContainerSnapshot? {
        lock.withLock { getCalls += 1 }
        return try await base.get(engineID)
    }
    func stop(_ container: ContainerSnapshot, timeout: Int32, signal: String?) async throws {
        try await base.stop(container, timeout: timeout, signal: signal)
    }
    func kill(_ container: ContainerSnapshot, signal: String) async throws { try await base.kill(container, signal: signal) }
    func delete(_ container: ContainerSnapshot, force: Bool) async throws { try await base.delete(container, force: force) }
    func deleteVolume(_ name: String) async throws { try await base.deleteVolume(name) }
    func supportsRename() async -> Bool { await base.supportsRename() }
    func rename(_ container: ContainerSnapshot, to name: String) async throws { try await base.rename(container, to: name) }

    // MARK: EngineContainerTools

    func createProcess(
        _ container: ContainerSnapshot, id: String, configuration: ProcessConfiguration, stdio: DockerProcessStdio
    ) async throws -> any EngineExecProcess {
        if let failure = lock.withLock({ createError }) { throw failure }
        guard let current = base.snapshot(container.id), current.status == .running else {
            throw DockerAPIError.conflict("container \(container.id) is not running")
        }
        let executable = configuration.executable
        let program = self.program(for: configuration)
        let available = lock.withLock { self.available.contains(executable) }
        let process = try FakeProcess(id: id, stdio: stdio) { process in
            guard available else { throw DockerAPIError.internalError("vmexec error: failed to find target executable \(executable)") }
            process.run(program)
        } onExit: { _ in
        }
        lock.withLock {
            configurations.append(configuration)
            processes[id] = process
        }
        return FakeExecProcess(process: process)
    }

    private func program(for configuration: ProcessConfiguration) -> FakeProgram {
        let arguments = configuration.arguments
        let root = self.root.path
        switch configuration.executable {
        case "stat":
            let follow = arguments.contains("-L")
            let path = arguments.last ?? ""
            return { io in
                var info = stat()
                let found = follow ? stat(root + path, &info) : lstat(root + path, &info)
                guard found == 0 else {
                    await io.write("stat: can't stat '\(path)': No such file or directory\n", to: .stderr)
                    return 1
                }
                await io.write("\(String(info.st_mode, radix: 16)) \(info.st_size) \(info.st_mtimespec.tv_sec)\n")
                return 0
            }
        case "readlink":
            let path = arguments.last ?? ""
            return { io in
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: root + path) else { return 1 }
                await io.write(target + "\n")
                return 0
            }
        case "ps":
            let (output, status) = lock.withLock { (psOutput, psStatus) }
            return { io in
                if status != 0 {
                    await io.write("ps: unrecognized option\n", to: .stderr)
                    return status
                }
                await io.write(output)
                return 0
            }
        default:
            return lock.withLock { program }(configuration)
        }
    }

    func log(_ container: ContainerSnapshot) async throws -> FileHandle {
        try FileHandle(forReadingFrom: logFile)
    }

    func stats(_ container: ContainerSnapshot) async throws -> ContainerStats {
        try lock.withLock {
            statsCalls += 1
            guard base.snapshot(container.id)?.status == .running else { throw DockerAPIError.conflict("not running") }
            guard !samples.isEmpty else { throw DockerAPIError.internalError("no samples") }
            defer { sampleIndex += 1 }
            return samples[min(sampleIndex, samples.count - 1)]
        }
    }

    func scratchDirectory() throws -> URL { scratch }

    func copyOut(_ container: ContainerSnapshot, source: String, destination: URL, requester: String?) async throws {
        lock.withLock {
            copies.append("out \(source)")
            copyRequesters.append("out \(requester ?? "-")")
        }
        let from = root.path + source
        guard FileManager.default.fileExists(atPath: from) else { throw DockerAPIError.internalError("copyOut: source not found '\(source)'") }
        try FileManager.default.copyItem(atPath: from, toPath: destination.path)
    }

    var copyInStatusCalls: [RuntimeStatus?] { lock.withLock { copyInStatuses } }

    func supportsCopyBeforeStart() async -> Bool { lock.withLock { copyBeforeStart } }

    func copyIn(_ container: ContainerSnapshot, source: URL, destination: String, mode: UInt32, requester: String?) async throws {
        let status = base.snapshot(container.id)?.status
        let failure: (any Error)? = lock.withLock {
            copies.append("in \(source.lastPathComponent) \(destination) \(String(mode, radix: 8))")
            copyRequesters.append("in \(requester ?? "-")")
            copyInStatuses.append(status)
            defer { copyInError = nil }
            return copyInError
        }
        if let failure { throw failure }
        let target = root.path + (destination.hasSuffix("/") ? destination : destination + "/") + source.lastPathComponent
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.copyItem(atPath: source.path, toPath: target)
        if !isDirectory.boolValue, (try? FileManager.default.attributesOfItem(atPath: target)[.type] as? FileAttributeType) == .typeRegular {
            chmod(target, mode_t(mode))
        }
    }
}

/// The tool routes on a real unix socket with `FakeTools`.
struct ToolHarness {
    typealias Client = DockerAPIServerTests.Client

    let tools: FakeTools
    let streams: DockerContainerStreams
    let server: DockerAPIServerTests.Harness

    static let boxID = Fixtures.id("b0c5")
    static let ttyID = Fixtures.id("77a1")
    static let stoppedID = Fixtures.id("5709")

    static func snapshots() -> [ContainerSnapshot] {
        var tty = Fixtures.dockerContainer(name: "term", dockerID: ttyID)
        tty.configuration.initProcess.terminal = true
        return [
            Fixtures.dockerContainer(name: "box", dockerID: boxID), tty,
            Fixtures.dockerContainer(name: "off", dockerID: stoppedID, status: .stopped, exitCode: 0),
        ]
    }

    static func start(
        options: DockerToolOptions = DockerToolOptions(logPollInterval: .milliseconds(20), logStatusInterval: .milliseconds(50), statsInterval: .milliseconds(50)),
        execLimits: DockerExecLimits = .init(), limits: DockerHTTPLimits = .init()
    ) async throws -> ToolHarness {
        let tools = try FakeTools(snapshots: snapshots())
        let streams = DockerContainerStreams(engine: tools, execLimits: execLimits, drain: .milliseconds(300), logOptions: options)
        let identities = DockerIdentityStore(persistence: nil)
        let server = try await DockerAPIServerTests.Harness.start(limits: limits) { router in
            ContainerRoutes.register(on: &router, engine: tools, identities: identities, streams: streams, now: { Fixtures.now })
            ContainerToolRoutes.register(on: &router, engine: tools, identities: identities, streams: streams, options: options)
        }
        return ToolHarness(tools: tools, streams: streams, server: server)
    }

    func stop() async throws {
        await streams.shutdown()
        try await server.stop()
        tools.cleanup()
    }

    struct Answer {
        let status: Int
        let head: String
        let body: [UInt8]

        var text: String { String(decoding: body, as: UTF8.self) }

        func json() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        }

        func header(_ name: String) -> String? {
            for line in head.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == name.lowercased() { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
    }

    /// One whole request on its own connection, its body read as bytes and de-chunked.
    func request(_ method: String, _ uri: String, body: [UInt8] = [], contentType: String = "application/json") async throws -> Answer {
        var raw: [UInt8] = []
        try await server.withClient { client in
            let head = "\(method) /v1.48\(uri) HTTP/1.1\r\nHost: d\r\nConnection: close\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
            var buffer = ByteBuffer(string: head)
            buffer.writeBytes(body)
            try await client.outbound.write(buffer)
            raw = try await Self.readAll(client)
        }
        return Self.parse(raw)
    }

    func request(_ method: String, _ uri: String, json: String) async throws -> Answer {
        try await request(method, uri, body: Array(json.utf8))
    }

    static func readAll(_ client: Client) async throws -> [UInt8] {
        var raw = Array(client.received.utf8)
        client.received = ""
        while let chunk = try await client.iterator.next() {
            raw += chunk.readableBytesView
        }
        return raw
    }

    static func parse(_ raw: [UInt8]) -> Answer {
        let separator: [UInt8] = Array("\r\n\r\n".utf8)
        guard let end = raw.firstRange(of: separator) else { return Answer(status: 0, head: String(decoding: raw, as: UTF8.self), body: []) }
        let head = String(decoding: raw[..<end.lowerBound], as: UTF8.self)
        var body = Array(raw[end.upperBound...])
        if head.lowercased().contains("transfer-encoding: chunked") {
            body = dechunk(body)
        }
        let status = Int(head.split(separator: " ", maxSplits: 2).dropFirst().first ?? "") ?? 0
        return Answer(status: status, head: head, body: body)
    }

    static func dechunk(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var rest = data[...]
        let crlf: [UInt8] = [13, 10]
        while let line = rest.firstRange(of: crlf) {
            guard let size = Int(String(decoding: rest[rest.startIndex..<line.lowerBound], as: UTF8.self), radix: 16), size > 0 else { break }
            let start = line.upperBound
            guard rest.distance(from: start, to: rest.endIndex) >= size else { break }
            out += rest[start..<(start + size)]
            rest = rest[min(start + size + 2, rest.endIndex)...]
        }
        return out
    }

    /// Payloads of multiplexed frames by stream.
    static func demux(_ bytes: [UInt8]) throws -> (stdout: String, stderr: String, frames: Int) {
        var decoder = StdMultiplexer.Decoder()
        let frames = try decoder.feed(ByteBuffer(bytes: bytes))
        let stdout = frames.filter { $0.0 == .stdout }.map { String(buffer: $0.1) }.joined()
        let stderr = frames.filter { $0.0 == .stderr }.map { String(buffer: $0.1) }.joined()
        return (stdout, stderr, frames.count)
    }
}
