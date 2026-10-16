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
import Synchronization
import Testing

@testable import DockerAPIService

@Suite(.timeLimit(.minutes(1)))
struct ExecStoreTests {
    static func container(env: [String] = ["PATH=/bin", "HOME=/root"]) -> DockerContainer {
        var snapshot = Fixtures.dockerContainer(name: "box", dockerID: ToolHarness.boxID)
        snapshot.configuration.initProcess.environment = env
        snapshot.configuration.initProcess.workingDirectory = "/srv"
        snapshot.configuration.initProcess.user = .raw(userString: "app")
        return DockerContainer(snapshot: snapshot, dockerID: ToolHarness.boxID, name: "box")
    }

    static func body(_ json: String) throws -> DockerExecCreateBody {
        try JSONDecoder().decode(DockerExecCreateBody.self, from: Data(json.utf8))
    }

    static func spec(_ engineID: String = "e1") -> DockerExecSpec {
        DockerExecSpec(
            engineID: engineID, containerID: "c-" + engineID, process: ProcessConfiguration(executable: "sh", arguments: [], environment: []),
            attachStdin: false, attachStdout: true, attachStderr: true)
    }

    /// A clock tests move by hand.
    final class Clock: Sendable {
        private let offset = Mutex(Duration.zero)
        let start = ContinuousClock.now

        func advance(_ by: Duration) { offset.withLock { $0 += by } }
        var now: ContinuousClock.Instant { start.advanced(by: offset.withLock { $0 }) }
    }

    @Test("an exec runs the container's process with its command, its variables over the container's, and its directory and user")
    func specFromBody() throws {
        let spec = try DockerExecSpec.make(
            try Self.body(#"{"Cmd":["env","-0"],"Env":["HOME=/tmp","EXTRA=1"],"WorkingDir":"/work","User":"1000:1000","Tty":true,"AttachStdin":true}"#),
            in: Self.container())
        #expect(spec.process.executable == "env")
        #expect(spec.process.arguments == ["-0"])
        #expect(spec.process.environment == ["PATH=/bin", "HOME=/tmp", "EXTRA=1"])
        #expect(spec.process.workingDirectory == "/work")
        #expect(spec.process.user == .raw(userString: "1000:1000"))
        #expect(spec.process.terminal)
        #expect(spec.attachStdin && !spec.attachStdout)
        #expect(spec.containerID == ToolHarness.boxID)

        // Control: without them, the container's own directory, user and environment.
        let plain = try DockerExecSpec.make(try Self.body(#"{"Cmd":["ls"]}"#), in: Self.container())
        #expect(plain.process.environment == ["PATH=/bin", "HOME=/root"])
        #expect(plain.process.workingDirectory == "/srv")
        #expect(plain.process.user == .raw(userString: "app"))
        #expect(!plain.process.terminal)
    }

    @Test("an exec without a command is dockerd's 400")
    func noCommand() throws {
        #expect(throws: DockerAPIError.badRequest("No exec command specified")) {
            try DockerExecSpec.make(try Self.body(#"{"Cmd":[]}"#), in: Self.container())
        }
        #expect(throws: Never.self) { try DockerExecSpec.make(try Self.body(#"{"Cmd":["true"]}"#), in: Self.container()) }
    }

    @Test("an exec runs once: a second start is refused while it runs and after it ran")
    func runsOnce() async throws {
        let store = DockerExecStore()
        let id = try await store.create(Self.spec())
        #expect(DockerIdentityTable.isDockerID(id))
        let inspected = try await store.inspect(id)
        #expect(!inspected.Running && inspected.ExitCode == nil)
        _ = try await store.begin(id)
        await #expect(throws: DockerAPIError.conflict("exec command \(id) is already running")) { try await store.begin(id) }
        await store.exited(id, code: 4)
        let done = try await store.inspect(id)
        #expect(!done.Running && done.ExitCode == 4)
        await #expect(throws: DockerAPIError.conflict("exec command \(id) has already run")) { try await store.begin(id) }
        await #expect(throws: DockerAPIError.notFound("No such exec instance: nope")) { try await store.inspect("nope") }
    }

    @Test("the inspect JSON carries ExitCode as null until the exit, then the code")
    func inspectJSON() async throws {
        let store = DockerExecStore()
        let id = try await store.create(Self.spec())
        let before = String(decoding: try DockerJSON.encoder.encode(try await store.inspect(id)), as: UTF8.self)
        #expect(before.contains(#""ExitCode":null"#))
        #expect(before.contains(#""Pid":0"#))
        #expect(before.contains(#""ContainerID":"c-e1""#))
        await store.exited(id, code: 0)
        let after = String(decoding: try DockerJSON.encoder.encode(try await store.inspect(id)), as: UTF8.self)
        #expect(after.contains(#""ExitCode":0"#))
    }

    @Test("execs are bounded per container and overall, and the unstarted and the exited expire while a running one stays")
    func boundsAndExpiry() async throws {
        let clock = Clock()
        let store = DockerExecStore(
            limits: DockerExecLimits(total: 3, perContainer: 2, unstartedLifetime: .seconds(60), exitedLifetime: .seconds(30)), now: { clock.now })
        let a = try await store.create(Self.spec("e1"))
        let b = try await store.create(Self.spec("e1"))
        await #expect(throws: DockerAPIError.self) { try await store.create(Self.spec("e1")) }
        let c = try await store.create(Self.spec("e2"))
        await #expect(throws: DockerAPIError.self) { try await store.create(Self.spec("e3")) }

        _ = try await store.begin(a)
        await store.exited(b, code: 0)
        clock.advance(.seconds(31))
        // The exited one is gone; the unstarted one and the running one stay.
        #expect(await store.count == 2)
        await #expect(throws: DockerAPIError.self) { try await store.inspect(b) }
        clock.advance(.seconds(30))
        #expect(await store.count == 1)
        await #expect(throws: DockerAPIError.self) { try await store.inspect(c) }
        clock.advance(.seconds(3600))
        #expect(try await store.inspect(a).Running)
    }

    @Test("a deleted container's execs are forgotten unless running, and shutdown refuses new ones")
    func releaseAndShutdown() async throws {
        let store = DockerExecStore()
        let running = try await store.create(Self.spec("e1"))
        let idle = try await store.create(Self.spec("e1"))
        let other = try await store.create(Self.spec("e2"))
        _ = try await store.begin(running)
        await store.release(engineID: "e1")
        #expect(try await store.inspect(running).Running)
        await #expect(throws: DockerAPIError.self) { try await store.inspect(idle) }
        // Control: another container's exec is untouched.
        #expect(try await store.inspect(other).ID == other)
        await store.shutdown()
        await #expect(throws: DockerAPIError.self) { try await store.create(Self.spec("e3")) }
    }

    @Test("a resize before the process exists waits for it and is applied by the start; one after the exit is ignored")
    func resizeBeforeStart() async throws {
        let store = DockerExecStore(limits: DockerExecLimits(resizeWait: .seconds(5)))
        let id = try await store.create(Self.spec())
        _ = try await store.begin(id)
        let resized = Task { try await store.resize(id, width: 120, height: 40) }
        try await Task.sleep(for: .milliseconds(50))
        let process = try FakeProcess(id: "p", stdio: .detached, onStart: { _ in }, onExit: { _ in })
        let pending = await store.started(id, process: FakeExecProcess(process: process))
        #expect(pending?.width == 120 && pending?.height == 40)
        try await resized.value
        // Running: straight to the process.
        try await store.resize(id, width: 80, height: 24)
        #expect(process.sizes == ["80x24"])
        await store.exited(id, code: 0)
        try await store.resize(id, width: 1, height: 1)
        #expect(process.sizes == ["80x24"])
    }

    @Test("a resize for an exec whose start failed, or never came, is refused")
    func resizeWithoutProcess() async throws {
        let store = DockerExecStore(limits: DockerExecLimits(resizeWait: .milliseconds(100)))
        let failed = try await store.create(Self.spec())
        _ = try await store.begin(failed)
        let resized = Task { try await store.resize(failed, width: 1, height: 1) }
        try await Task.sleep(for: .milliseconds(20))
        await store.exited(failed, code: 127)
        await #expect(throws: DockerAPIError.badRequest("exec process is not started")) { try await resized.value }
        let never = try await store.create(Self.spec())
        await #expect(throws: DockerAPIError.internalError("timeout waiting for exec session ready")) {
            try await store.resize(never, width: 1, height: 1)
        }
    }

    @Test("a start that fails gets dockerd's status for why")
    func startFailureStatus() {
        typealias Routes = ContainerToolRoutes.Routes<FakeTools>
        #expect(Routes.startFailureStatus("vmexec error: failed to find target executable nope") == 127)
        #expect(Routes.startFailureStatus("exec: \"x\": executable file not found in $PATH") == 127)
        #expect(Routes.startFailureStatus("open /bin/x: permission denied") == 126)
        #expect(Routes.startFailureStatus("the VM went away") == 128)
    }
}

/// Exec over a real unix socket, the way `docker exec` drives it.
@Suite(.timeLimit(.minutes(1)))
struct ExecStreamTests {
    typealias Client = DockerAPIServerTests.Client

    static func startRequest(_ id: String, tty: Bool, detach: Bool = false) -> String {
        let body = #"{"Detach":\#(detach),"Tty":\#(tty)}"#
        return "POST /v1.48/exec/\(id)/start HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    static func create(_ h: ToolHarness, _ container: String, _ json: String) async throws -> String {
        let answer = try await h.request("POST", "/containers/\(container)/exec", json: json)
        #expect(answer.status == 201)
        return try #require(try answer.json()["Id"] as? String)
    }

    static func exitCode(_ h: ToolHarness, _ id: String) async throws -> Int? {
        try await h.request("GET", "/exec/\(id)/json").json()["ExitCode"] as? Int
    }

    @Test("exec -it: raw output, stdin in and its half-close reaching the process, the resize applied, and the exit code there when the stream ends")
    func interactiveTTY() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.program = { _ in FakePrograms.echo(5) }
        let id = try await Self.create(h, "box", #"{"Cmd":["sh"],"Tty":true,"AttachStdin":true,"AttachStdout":true,"AttachStderr":true}"#)
        try await h.server.withClient { exec in
            try await exec.send(Self.startRequest(id, tty: true) + "early ")
            let head = try await exec.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 101 UPGRADED"))
            #expect(head.contains("application/vnd.docker.raw-stream"))
            #expect(try await h.request("POST", "/exec/\(id)/resize?h=30&w=100").status == 200)
            #expect(try await exec.read(through: "got:early ;") == "ready;got:early ;")
            // Control: the process has not seen its input end before the half-close.
            #expect(h.tools.process(id)?.notes.contains("eof") == false)
            #expect(try await h.request("GET", "/exec/\(id)/json").json()["Running"] as? Bool == true)
            exec.closeWrite()
            // A terminal has no stderr: "bye;" has nowhere to go.
            #expect(try await exec.readToEnd() == "eof;")
            #expect(try await Self.exitCode(h, id) == 5)
        }
        #expect(h.tools.process(id)?.sizes == ["100x30"])
        #expect(h.tools.lastConfiguration?.terminal == true)
    }

    @Test("exec -i without a tty: stdout and stderr come back framed")
    func multiplexed() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.program = { _ in FakePrograms.echo(3) }
        let id = try await Self.create(h, "box", #"{"Cmd":["sh"],"AttachStdin":true,"AttachStdout":true,"AttachStderr":true}"#)
        try await h.server.withClient { exec in
            try await exec.send(Self.startRequest(id, tty: false))
            #expect(try await exec.read(through: "\r\n\r\n").contains("application/vnd.docker.multiplexed-stream"))
            try await exec.send("x")
            exec.closeWrite()
            let raw = try await ToolHarness.readAll(exec)
            let streams = try ToolHarness.demux(raw)
            #expect(streams.stdout == "ready;got:x;eof;")
            #expect(streams.stderr == "bye;")
        }
        #expect(try await Self.exitCode(h, id) == 3)
    }

    @Test("only the streams the exec asked for are bound")
    func onlyAskedStreams() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.program = { _ in FakePrograms.say("out", stderr: "err", code: 0) }
        let id = try await Self.create(h, "box", #"{"Cmd":["sh"],"AttachStdout":true}"#)
        try await h.server.withClient { exec in
            try await exec.send(Self.startRequest(id, tty: false))
            _ = try await exec.read(through: "\r\n\r\n")
            let streams = try ToolHarness.demux(try await ToolHarness.readAll(exec))
            #expect(streams.stdout == "out")
            #expect(streams.stderr == "")
        }
        let process = try #require(h.tools.process(id))
        #expect(process.bound.stdin == false && process.bound.stdout && process.bound.stderr == false)
    }

    @Test("a command the container does not have: the error on the stream and dockerd's 127")
    func missingCommand() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let id = try await Self.create(h, "box", #"{"Cmd":["nope"],"AttachStdout":true,"AttachStderr":true}"#)
        try await h.server.withClient { exec in
            try await exec.send(Self.startRequest(id, tty: false))
            _ = try await exec.read(through: "\r\n\r\n")
            let streams = try ToolHarness.demux(try await ToolHarness.readAll(exec))
            #expect(streams.stdout.contains("failed to find target executable nope"))
        }
        #expect(try await Self.exitCode(h, id) == 127)
        // Control: a command it has exits with its own status.
        let good = try await Self.create(h, "box", #"{"Cmd":["sh"],"AttachStdout":true}"#)
        h.tools.program = { _ in FakePrograms.exit(0) }
        try await h.server.withClient { exec in
            try await exec.send(Self.startRequest(good, tty: false))
            _ = try await ToolHarness.readAll(exec)
        }
        #expect(try await Self.exitCode(h, good) == 0)
    }

    @Test("a detached exec answers 200 at once, runs without stdio, and its exit is recorded")
    func detached() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let gate = DockerLatch()
        h.tools.program = { _ in
            { _ in
                await gate.wait()
                return 9
            }
        }
        let id = try await Self.create(h, "box", #"{"Cmd":["sh"]}"#)
        let started = try await h.request("POST", "/exec/\(id)/start", json: #"{"Detach":true}"#)
        #expect(started.status == 200)
        #expect(try await h.request("GET", "/exec/\(id)/json").json()["Running"] as? Bool == true)
        let process = try #require(h.tools.process(id))
        #expect(process.bound.stdin == false && process.bound.stdout == false && process.bound.stderr == false)
        gate.open()
        #expect(await StreamHarness.eventually { (try? await Self.exitCode(h, id)) == 9 })
        #expect(try await h.request("POST", "/exec/\(id)/start", json: #"{"Detach":true}"#).status == 409)
    }

    @Test("exec create on a stopped container is dockerd's 409, on a missing one a 404, and start of an unknown exec a 404")
    func refusals() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let stopped = try await h.request("POST", "/containers/off/exec", json: #"{"Cmd":["sh"]}"#)
        #expect(stopped.status == 409)
        #expect(try stopped.json()["message"] as? String == "container \(ToolHarness.stoppedID) is not running")
        #expect(try await h.request("POST", "/containers/ghost/exec", json: #"{"Cmd":["sh"]}"#).status == 404)
        #expect(try await h.request("POST", "/containers/box/exec", json: #"{"Cmd":[]}"#).status == 400)
        let unknown = try await h.request("POST", "/exec/\(Fixtures.id("ee"))/start", json: #"{"Detach":true}"#)
        #expect(unknown.status == 404)
        #expect(try await h.request("POST", "/exec/x/resize?h=a&w=1").status == 400)
    }

    @Test("an exec whose container stopped before its start is refused before the upgrade")
    func containerStoppedBeforeStart() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let id = try await Self.create(h, "box", #"{"Cmd":["sh"],"AttachStdout":true}"#)
        h.tools.base.update(String(ToolHarness.boxID.prefix(12))) { $0.status = .stopped }
        let answer = try await h.request("POST", "/exec/\(id)/start", json: #"{"Detach":false}"#)
        #expect(answer.status == 409)
        // Control: nothing was run, so it may still start once the container runs again.
        h.tools.base.update(String(ToolHarness.boxID.prefix(12))) { $0.status = .running }
        #expect(try await h.request("POST", "/exec/\(id)/start", json: #"{"Detach":true}"#).status == 200)
    }
}
