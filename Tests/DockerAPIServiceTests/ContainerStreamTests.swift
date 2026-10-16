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
import NIOPosix
import Synchronization
import Testing

@testable import DockerAPIService

/// The container routes on a real unix socket with a fake engine, driven the way the Docker CLI
/// drives `run`: attach, wait, start, each on its own connection, in raw bytes.
struct StreamHarness {
    typealias Client = DockerAPIServerTests.Client

    let engine: FakeEngine
    let streams: DockerContainerStreams
    let server: DockerAPIServerTests.Harness

    static func start(
        snapshots: [ContainerSnapshot] = [],
        attachLimits: DockerAttachLimits = DockerAttachLimits(peerCheckInterval: .milliseconds(20)),
        waitLimits: DockerWaitLimits = DockerWaitLimits(pollInterval: .milliseconds(20))
    ) async throws -> StreamHarness {
        let engine = FakeEngine(snapshots: snapshots)
        let streams = DockerContainerStreams(engine: engine, attachLimits: attachLimits, waitLimits: waitLimits, drain: .milliseconds(500))
        let identities = DockerIdentityStore(persistence: nil)
        let server = try await DockerAPIServerTests.Harness.start { router in
            ContainerRoutes.register(on: &router, engine: engine, identities: identities, streams: streams, now: { Fixtures.now })
        }
        return StreamHarness(engine: engine, streams: streams, server: server)
    }

    func stop() async throws {
        await streams.shutdown()
        try await server.stop()
    }

    /// One whole request on its own connection.
    func request(_ method: String, _ uri: String, body: String = "") async throws -> (status: Int, body: String) {
        var answer = ""
        try await server.withClient { client in
            try await client.send(
                "\(method) /v1.48\(uri) HTTP/1.1\r\nHost: d\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            )
            answer = try await client.readToEnd()
        }
        let status = Int(answer.split(separator: " ", maxSplits: 2).dropFirst().first ?? "") ?? 0
        let content = answer.range(of: "\r\n\r\n").map { String(answer[$0.upperBound...]) } ?? ""
        return (status, content)
    }

    /// Creates a container the way `docker run` does, and returns its engine ID.
    func create(_ name: String, tty: Bool, autoRemove: Bool = false, program: FakeProgram? = nil) async throws -> String {
        let body = """
            {"Image":"alpine","Cmd":["sh"],"Tty":\(tty),"OpenStdin":true,"StdinOnce":true,"AttachStdin":true,"AttachStdout":true,"AttachStderr":true,\
            "HostConfig":{"AutoRemove":\(autoRemove)}}
            """
        let created = try await request("POST", "/containers/create?name=\(name)", body: body)
        #expect(created.status == 201)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(created.body.utf8)) as? [String: Any])
        let engineID = String(try #require(object["Id"] as? String).prefix(12))
        engine.programs[engineID] = program
        return engineID
    }

    static func attachRequest(_ name: String, streams: String = "stdin=1&stdout=1&stderr=1") -> String {
        "POST /v1.48/containers/\(name)/attach?stream=1&\(streams) HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
    }

    static func waitRequest(_ name: String, _ condition: String) -> String {
        "POST /v1.48/containers/\(name)/wait?condition=\(condition) HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n"
    }

    /// Sends a wait and returns once its head is back, as the CLI does before it starts.
    static func beginWait(_ client: Client, _ name: String, _ condition: String) async throws {
        try await client.send(waitRequest(name, condition))
        let head = try await client.read(through: "\r\n\r\n")
        #expect(head.hasPrefix("HTTP/1.1 200"))
    }

    /// The `{"StatusCode":…}` object a wait answers with.
    static func waitAnswer(_ client: Client) async throws -> [String: Any] {
        let body = try await client.readToEnd()
        let start = try #require(body.firstIndex(of: "{"))
        let end = try #require(body.lastIndex(of: "}"))
        return try #require(try JSONSerialization.jsonObject(with: Data(body[start...end].utf8)) as? [String: Any])
    }

    /// Returns once every event loop has run what was queued on it before the call.
    static func loopsRan() async throws {
        for loop in MultiThreadedEventLoopGroup.singleton.makeIterator() {
            try await loop.submit {}.get()
        }
    }

    /// Waits until `condition` holds, for at most `time`.
    static func eventually(within time: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: time)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ContainerStreamTests {
    @Test("run -it: early stdin arrives first, output is raw, the half-close reaches stdin, and the exit ends the stream")
    func interactiveTTY() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("web", tty: true, program: FakePrograms.echo(3))
        try await h.server.withClient { attach in
            // Stdin typed before the 101 came back, in the same write as the request.
            try await attach.send(StreamHarness.attachRequest("web") + "early ")
            let upgraded = try await attach.read(through: "\r\n\r\n")
            #expect(upgraded.hasPrefix("HTTP/1.1 101 UPGRADED"))
            #expect(upgraded.contains("application/vnd.docker.raw-stream"))
            try await h.server.withClient { waiter in
                try await StreamHarness.beginWait(waiter, "web", "next-exit")
                #expect(try await h.request("POST", "/containers/web/start").status == 204)
                // Raw: no frame headers in front of the output.
                #expect(try await attach.read(through: "got:early ;") == "ready;got:early ;")
                try await attach.send("late")
                #expect(try await attach.read(through: "got:late;") == "got:late;")
                // Control: until the client half-closes, the process has not seen its input end.
                #expect(h.engine.process(engineID)?.notes.contains("eof") == false)
                attach.closeWrite()
                // With a tty there is no stderr pipe, so the process's "bye;" has nowhere to go.
                #expect(try await attach.readToEnd() == "eof;")
                #expect(h.engine.process(engineID)?.notes == ["read early ", "read late", "eof"])
                #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 3)
            }
        }
        #expect(h.engine.bootstraps == ["\(engineID) stdin stdout -"])
        #expect(await StreamHarness.eventually { await h.streams.attaches.count == 0 })
    }

    @Test("run -i without a tty: stdout and stderr come back framed, each in order")
    func interactiveMultiplexed() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("job", tty: false, program: FakePrograms.echo(0))
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("job"))
            #expect(try await attach.read(through: "\r\n\r\n").contains("application/vnd.docker.multiplexed-stream"))
            try await h.server.withClient { waiter in
                try await StreamHarness.beginWait(waiter, "job", "next-exit")
                #expect(try await h.request("POST", "/containers/job/start").status == 204)
                try await attach.send("x")
                attach.closeWrite()
                let raw = try await attach.readToEnd()
                var decoder = StdMultiplexer.Decoder()
                let frames = try decoder.feed(ByteBuffer(bytes: Array(raw.utf8)))
                let stdout = frames.filter { $0.0 == .stdout }.map { String(buffer: $0.1) }.joined()
                let stderr = frames.filter { $0.0 == .stderr }.map { String(buffer: $0.1) }.joined()
                #expect(stdout == "ready;got:x;eof;")
                #expect(stderr == "bye;")
                // Control: every byte was in a frame; raw output would not decode to these.
                #expect(frames.map { $0.1.readableBytes + StdMultiplexer.headerSize }.reduce(0, +) == raw.utf8.count)
                #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 0)
            }
        }
        #expect(h.engine.bootstraps == ["\(engineID) stdin stdout stderr"])
    }

    @Test("a client that does not read holds the process back instead of the agent buffering its output")
    func backpressure() async throws {
        // Far more than the pipe, the agent and the sockets hold together (about 1 MB, measured;
        // 1.6 MB at most in 50 runs on a loaded Mac), so a process that could write half of it
        // unread would mean output buffered without bound somewhere.
        let chunk = 64 << 10
        let chunks = 256
        let total = chunk * chunks
        // Bytes the pipe has taken from the process, and whether it is inside a write that has
        // not returned. Written through, as a real process writes: what the process's own
        // async writer has accepted is not yet the agent's to hold.
        let progress = Mutex((written: 0, writing: false))
        let program: FakeProgram = { io in
            let data = ByteBuffer(repeating: UInt8(ascii: "x"), count: chunk)
            for _ in 0..<chunks {
                progress.withLock { $0.writing = true }
                do {
                    try await io.writeThrough(data)
                } catch {
                    return 1
                }
                progress.withLock {
                    $0.writing = false
                    $0.written += chunk
                }
            }
            return 0
        }
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("flood", tty: true, program: program)
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("flood", streams: "stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/flood/start").status == 204)
            // Nothing read yet. Wait until the process is held inside a write the pipe does not
            // take, with nothing moving across ten looks in a row. Before each look every event
            // loop runs what was queued on it, so a still look means the loops ran and nothing
            // moved, not that they had no turn. A busy machine only makes this take longer:
            // nothing here depends on how much fits before it stalls, or how fast it gets there.
            var held: (written: Int, writing: Bool)?
            var still = 0
            for _ in 0..<500 {
                let before = progress.withLock { $0 }
                if before.written == total { break }
                try await StreamHarness.loopsRan()
                try await Task.sleep(for: .milliseconds(20))
                let after = progress.withLock { $0 }
                still = after.writing && after.written == before.written ? still + 1 : 0
                if still == 10 {
                    held = after
                    break
                }
            }
            // The process is suspended in a write, with most of its output still unwritten:
            // the unread client holds it back.
            let stalled = try #require(held)
            #expect(stalled.writing)
            #expect(stalled.written > 0)
            #expect(stalled.written < total / 2)
            // Control: once the client reads, all of it arrives.
            var received = attach.received.utf8.count
            while let piece = try await attach.iterator.next() {
                received += piece.readableBytes
            }
            #expect(received == total)
        }
        #expect(progress.withLock { $0.written } == total)
    }

    @Test("output still on its way when the process exits reaches a client that reads it late")
    func slowReaderAfterExit() async throws {
        let size = 256 << 10
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("burst", tty: true, program: FakePrograms.say(String(repeating: "z", count: size), code: 0))
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("burst", streams: "stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            try await h.server.withClient { waiter in
                try await StreamHarness.beginWait(waiter, "burst", "next-exit")
                #expect(try await h.request("POST", "/containers/burst/start").status == 204)
                // Control: the process has exited while most of its output waits for the client.
                #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 0)
            }
            // Longer than the harness's 500 ms drain: the client is slow, not gone.
            try await Task.sleep(for: .seconds(1))
            var received = attach.received.utf8.count
            while let piece = try await attach.iterator.next() {
                received += piece.readableBytes
            }
            #expect(received == size)
        }
    }

    @Test("a pipe something else holds open past the exit is read until it stays quiet, then the stream ends")
    func quietPipe() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("daemon", tty: true, program: FakePrograms.say("bye;", code: 0))
        h.engine.holdOutputOpen.insert(engineID)
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("daemon", streams: "stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/daemon/start").status == 204)
            #expect(try await attach.read(through: "bye;") == "bye;")
            let exited = ContinuousClock.now
            #expect(try await attach.readToEnd() == "")
            // Control: it was not ended at the exit, but after the harness's 500 ms of quiet.
            #expect(exited.duration(to: .now) >= .milliseconds(400))
        }
    }

    @Test("rm -f of a running container answers removed with the exit the deletion caused")
    func forcedRemoval() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("doomed", tty: false)
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "doomed", "removed")
            #expect(try await h.request("POST", "/containers/doomed/start").status == 204)
            // Control: the wait holds while the container runs.
            #expect(await h.streams.waits.pending == 1)
            #expect(try await h.request("DELETE", "/containers/doomed?force=1").status == 204)
            #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 137)
        }
    }

    @Test("input the client sends right before its half-close all reaches a slow process before EOF")
    func stdinDrained() async throws {
        let total = 2 << 20
        let program: FakeProgram = { io in
            var count = 0
            do {
                for try await chunk in io.stdin! {
                    count += chunk.readableBytes
                    // A slow reader: the agent still holds input when the client's input ends.
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch {
                return 1
            }
            await io.write("n=\(count);")
            return 0
        }
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("sink", tty: true, program: program)
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("sink", streams: "stdin=1&stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/sink/start").status == 204)
            try await attach.outbound.write(ByteBuffer(repeating: UInt8(ascii: "y"), count: total))
            attach.closeWrite()
            #expect(try await attach.readToEnd() == "n=\(total);")
        }
        // Control: input a process never reads does not hold up the end of its stream.
        _ = try await h.create("deaf", tty: true) { io in
            await io.write("up;")
            try? await Task.sleep(for: .milliseconds(200))
            return 0
        }
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("deaf", streams: "stdin=1&stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/deaf/start").status == 204)
            let outbound = attach.outbound
            let flood = Task { try? await outbound.write(ByteBuffer(repeating: UInt8(ascii: "y"), count: total)) }
            #expect(try await attach.readToEnd() == "up;")
            flood.cancel()
        }
    }

    @Test("an attach that asked only for stdout gets no stderr pipe and no stdin pipe")
    func streamsAsAsked() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("job", tty: false, program: FakePrograms.say("out;", stderr: "err;", code: 4))
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("job", streams: "stdout=1"))
            _ = try await attach.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/job/start").status == 204)
            let raw = try await attach.readToEnd()
            var decoder = StdMultiplexer.Decoder()
            let frames = try decoder.feed(ByteBuffer(bytes: Array(raw.utf8)))
            #expect(frames.map(\.0) == [.stdout])
            #expect(frames.map { String(buffer: $0.1) } == ["out;"])
        }
        #expect(h.engine.bootstraps == ["\(engineID) - stdout -"])
    }

    @Test("a process that exits at once is heard by the wait the CLI registered first, 30 times over")
    func immediateExit() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        for code in 0..<30 {
            _ = try await h.create("job\(code)", tty: false, program: FakePrograms.exit(Int32(code)))
            try await h.server.withClient { waiter in
                try await StreamHarness.beginWait(waiter, "job\(code)", "next-exit")
                #expect(try await h.request("POST", "/containers/job\(code)/start").status == 204)
                #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == code)
            }
        }
        // Without attaches, the start binds no stdio, as run -d does.
        #expect(h.engine.bootstraps.allSatisfy { $0.hasSuffix(" - - -") })
        // Control: not-running on a container that already exited answers at once, with its status.
        #expect(try await h.request("POST", "/containers/job7/wait").body.contains(#"{"StatusCode":7}"#))
    }

    @Test("run -d: a detached process is held, so stop's exit status reaches the wait")
    func detached() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("web", tty: false)
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "web", "next-exit")
            #expect(try await h.request("POST", "/containers/web/start").status == 204)
            #expect(await h.streams.processes.holds(engineID))
            // Control: a second start of the running container is not modified.
            #expect(try await h.request("POST", "/containers/web/start").status == 304)
            #expect(try await h.request("POST", "/containers/web/stop").status == 204)
            #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 0)
        }
        #expect(await StreamHarness.eventually { await !h.streams.processes.holds(engineID) })
    }

    @Test("a failed start answers the wait with the error body and lets the attach go")
    func failedStart() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("web", tty: true)
        h.engine.startError = DockerAPIError.badRequest("exec: /bin/nope: not found")
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("web"))
            _ = try await attach.read(through: "\r\n\r\n")
            try await h.server.withClient { waiter in
                try await StreamHarness.beginWait(waiter, "web", "next-exit")
                let start = try await h.request("POST", "/containers/web/start")
                #expect(start.status == 400)
                #expect(start.body.contains("exec: /bin/nope: not found"))
                let answer = try await StreamHarness.waitAnswer(waiter)
                #expect(answer["StatusCode"] as? Int == 128)
                #expect((answer["Error"] as? [String: Any])?["Message"] as? String == "exec: /bin/nope: not found")
            }
            #expect(try await attach.readToEnd() == "")
        }
        // Control: the next start works, and its exit carries no error.
        h.engine.programs[engineID] = FakePrograms.exit(0)
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "web", "next-exit")
            #expect(try await h.request("POST", "/containers/web/start").status == 204)
            let answer = try await StreamHarness.waitAnswer(waiter)
            #expect(answer["StatusCode"] as? Int == 0)
            #expect(answer["Error"] == nil)
        }
    }

    @Test("run --rm: removed answers once the engine deletes the container, and a failed start removes it")
    func autoRemove() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("once", tty: false, autoRemove: true, program: FakePrograms.exit(4))
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "once", "removed")
            #expect(try await h.request("POST", "/containers/once/start").status == 204)
            #expect(try await StreamHarness.waitAnswer(waiter)["StatusCode"] as? Int == 4)
        }
        #expect(try await h.request("GET", "/containers/once/json").status == 404)

        _ = try await h.create("broken", tty: false, autoRemove: true)
        h.engine.startError = DockerAPIError.badRequest("exec: /bin/nope: not found")
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "broken", "removed")
            #expect(try await h.request("POST", "/containers/broken/start").status == 400)
            let answer = try await StreamHarness.waitAnswer(waiter)
            #expect(answer["StatusCode"] as? Int == 128)
            #expect((answer["Error"] as? [String: Any])?["Message"] as? String == "exec: /bin/nope: not found")
        }
        #expect(try await h.request("GET", "/containers/broken/json").status == 404)

        // Control: without --rm a failed start leaves the container, and removed keeps waiting.
        _ = try await h.create("kept", tty: false)
        h.engine.startError = DockerAPIError.badRequest("exec: /bin/nope: not found")
        #expect(try await h.request("POST", "/containers/kept/start").status == 400)
        #expect(try await h.request("GET", "/containers/kept/json").status == 200)
    }

    @Test("a client that leaves its wait is forgotten")
    func waitDisconnect() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("web", tty: false)
        try await h.server.withClient { waiter in
            try await StreamHarness.beginWait(waiter, "web", "removed")
            // Control: while the client is there, the wait is held.
            #expect(await h.streams.waits.pending == 1)
        }
        #expect(await StreamHarness.eventually { await h.streams.waits.pending == 0 })
    }

    @Test("resize sizes the terminal of a process this service started, and only that")
    func resize() async throws {
        var foreign = Fixtures.configuration(id: "cli")
        foreign.initProcess.terminal = true
        let h = try await StreamHarness.start(snapshots: [Fixtures.snapshot(foreign)])
        defer { Task { try? await h.stop() } }
        let engineID = try await h.create("web", tty: true)
        // Not running yet: dockerd's 409.
        #expect(try await h.request("POST", "/containers/web/resize?h=40&w=120").status == 409)
        #expect(try await h.request("POST", "/containers/web/start").status == 204)
        #expect(try await h.request("POST", "/containers/web/resize?h=40&w=120").status == 200)
        #expect(h.engine.process(engineID)?.sizes == ["120x40"])
        #expect(try await h.request("POST", "/containers/web/resize?h=forty&w=120").status == 400)
        // Control: a container `container run -it` started has its terminal sized there.
        let other = try await h.request("POST", "/containers/cli/resize?h=40&w=120")
        #expect(other.status == 404)
        #expect(other.body.contains("only of a container its Docker API started"))
        // A container without a terminal has nothing to size.
        let plainID = try await h.create("plain", tty: false)
        #expect(try await h.request("POST", "/containers/plain/start").status == 204)
        #expect(try await h.request("POST", "/containers/plain/resize?h=40&w=120").status == 200)
        #expect(h.engine.process(plainID)?.sizes == [])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DockerAttachStoreTests {
    @Test("attaches are bounded per container and overall")
    func limits() async throws {
        let store = DockerAttachStore(limits: DockerAttachLimits(perContainer: 2, total: 3))
        _ = try await store.reserve(engineID: "a", options: .init(stdout: true))
        _ = try await store.reserve(engineID: "a", options: .init(stdout: true))
        await #expect(throws: DockerAPIError(.tooManyRequests, "container a already has 2 attaches waiting for it to start")) {
            try await store.reserve(engineID: "a", options: .init(stdout: true))
        }
        // Control: another container has room, up to the overall cap.
        _ = try await store.reserve(engineID: "b", options: .init(stdout: true))
        await #expect(throws: DockerAPIError.self) { try await store.reserve(engineID: "c", options: .init(stdout: true)) }
        #expect(await store.waiting(for: "a") == 2)
        await store.release(engineID: "a")
        // Released before their connections arrived: they are let go when they do, and the idle
        // timer forgets them should they never come.
        #expect(await store.waiting(for: "b") == 1)
    }

    @Test("an attach to a running container is refused with 409, and one before the start is upgraded")
    func runningConflict() async throws {
        let h = try await StreamHarness.start()
        defer { Task { try? await h.stop() } }
        _ = try await h.create("web", tty: true)
        _ = try await h.create("idle", tty: true)
        #expect(try await h.request("POST", "/containers/web/start").status == 204)
        let refused = try await h.request("POST", "/containers/web/attach?stream=1&stdout=1")
        #expect(refused.status == 409)
        #expect(refused.body.contains("it is already running"))
        // Control: the container that has not started takes the attach.
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("idle"))
            #expect(try await attach.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 101"))
        }
    }

    @Test("a parked attach is let go after its idle timeout")
    func idleTimeout() async throws {
        let h = try await StreamHarness.start(attachLimits: DockerAttachLimits(idleTimeout: .milliseconds(300), peerCheckInterval: .seconds(60)))
        defer { Task { try? await h.stop() } }
        _ = try await h.create("web", tty: true)
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("web"))
            _ = try await attach.read(through: "\r\n\r\n")
            // Control: within its timeout it is held.
            #expect(await h.streams.attaches.count == 1)
            #expect(try await attach.readToEnd() == "")
        }
        #expect(await h.streams.attaches.count == 0)
    }

    @Test("a parked attach is let go when its client hangs up, and kept when it only ends its input")
    func disconnect() async throws {
        let h = try await StreamHarness.start(attachLimits: DockerAttachLimits(peerCheckInterval: .milliseconds(20)))
        defer { Task { try? await h.stop() } }
        _ = try await h.create("web", tty: true)
        try await h.server.withClient { kept in
            try await kept.send(StreamHarness.attachRequest("web"))
            _ = try await kept.read(through: "\r\n\r\n")
            kept.closeWrite()
            try await h.server.withClient { gone in
                try await gone.send(StreamHarness.attachRequest("web"))
                _ = try await gone.read(through: "\r\n\r\n")
                #expect(await h.streams.attaches.count == 2)
            }
            // The client that hung up is let go.
            #expect(await StreamHarness.eventually { await h.streams.attaches.count == 1 })
            // Control: the half-closed one is still waiting for its start well after that.
            try await Task.sleep(for: .milliseconds(200))
            #expect(await h.streams.attaches.count == 1)
        }
    }

    @Test("deleting a container lets its parked attaches go, and shutdown lets every one go")
    func deleteAndShutdown() async throws {
        let h = try await StreamHarness.start()
        _ = try await h.create("web", tty: true)
        _ = try await h.create("db", tty: false)
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("web"))
            _ = try await attach.read(through: "\r\n\r\n")
            // Control: held until the delete.
            #expect(await h.streams.attaches.count == 1)
            #expect(try await h.request("DELETE", "/containers/web").status == 204)
            #expect(try await attach.readToEnd() == "")
        }
        #expect(await StreamHarness.eventually { await h.streams.attaches.count == 0 })
        try await h.server.withClient { attach in
            try await attach.send(StreamHarness.attachRequest("db"))
            _ = try await attach.read(through: "\r\n\r\n")
            await h.streams.shutdown()
            #expect(try await attach.readToEnd() == "")
        }
        let refused = try await h.request("POST", "/containers/db/attach?stream=1&stdout=1")
        #expect(refused.status == 503)
        try await h.server.stop()
    }

    @Test("past the per-container limit an attach is refused before the upgrade")
    func attachLimitOverHTTP() async throws {
        let h = try await StreamHarness.start(attachLimits: DockerAttachLimits(perContainer: 1, peerCheckInterval: .milliseconds(20)))
        defer { Task { try? await h.stop() } }
        _ = try await h.create("web", tty: true)
        _ = try await h.create("db", tty: true)
        try await h.server.withClient { first in
            try await first.send(StreamHarness.attachRequest("web"))
            _ = try await first.read(through: "\r\n\r\n")
            #expect(try await h.request("POST", "/containers/web/attach?stream=1&stdout=1").status == 429)
            // Control: another container's attach is upgraded.
            try await h.server.withClient { other in
                try await other.send(StreamHarness.attachRequest("db"))
                #expect(try await other.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 101"))
            }
        }
    }
}
