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

@Suite(.timeLimit(.minutes(1)))
struct LogFileTests {
    /// A log file with `text`, open for reading.
    static func file(_ text: String) throws -> (URL, FileHandle) {
        let url = FileManager.default.temporaryDirectory.appending(path: "dapi-log-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return (url, try FileHandle(forReadingFrom: url))
    }

    static func readAll(_ file: inout DockerLogFile) throws -> String {
        var text = ""
        while true {
            let chunk = try file.next()
            if chunk.isEmpty { return text }
            text += String(decoding: chunk, as: UTF8.self)
        }
    }

    @Test("tail keeps the last N lines, counting a last line without its newline, and 0 and all as dockerd reads them")
    func tail() throws {
        let cases: [(String, Int?, String)] = [
            ("a\nb\nc\n", 2, "b\nc\n"),
            ("a\nb\nc", 2, "b\nc"),
            ("a\nb\nc\n", 5, "a\nb\nc\n"),
            ("a\nb\nc\n", nil, "a\nb\nc\n"),
            ("a\nb\nc\n", 0, ""),
            ("a\n\nc\n", 2, "\nc\n"),
        ]
        for (text, lines, expected) in cases {
            let (url, handle) = try Self.file(text)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
            }
            var file = try DockerLogFile(fd: handle.fileDescriptor)
            try file.seek(tail: lines)
            #expect(try Self.readAll(&file) == expected, "tail \(String(describing: lines)) of \(text.debugDescription)")
        }
    }

    @Test("tail looks across chunk boundaries")
    func tailAcrossChunks() throws {
        let line = String(repeating: "x", count: 1000) + "\n"
        let text = String(repeating: line, count: 200)
        let (url, handle) = try Self.file(text)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        var file = try DockerLogFile(fd: handle.fileDescriptor)
        try file.seek(tail: 130)
        #expect(try Self.readAll(&file) == String(repeating: line, count: 130))
    }

    @Test("a log the engine rewrote from the start is read again from the top; one that only grew is read on")
    func rollover() throws {
        let (url, handle) = try Self.file("first line\n")
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        var file = try DockerLogFile(fd: handle.fileDescriptor)
        #expect(try Self.readAll(&file) == "first line\n")
        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("grown\n".utf8))
        // Control: growth is read from where reading stopped.
        #expect(try Self.readAll(&file) == "grown\n")
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("[container log rolled over: X]\nnew output that is long enough\n".utf8))
        try writer.close()
        #expect(try Self.readAll(&file) == "[container log rolled over: X]\nnew output that is long enough\n")
    }

    @Test("timestamps stamp each line once, also when a line is split across reads, with nine fraction digits")
    func timestamps() {
        let time = Date(timeIntervalSince1970: 1_800_000_000.5)
        var framer = DockerLogFramer(multiplexed: false, stream: .stdout, timestamps: true)
        let first = String(buffer: framer.frame(Data("one\ntw".utf8), at: time))
        let second = String(buffer: framer.frame(Data("o\nthree\n".utf8), at: time))
        let stamp = "2027-01-15T08:00:00.500000000Z"
        #expect(first == "\(stamp) one\n\(stamp) tw")
        #expect(second == "o\n\(stamp) three\n")
        // Control: without timestamps the bytes pass as they are.
        var plain = DockerLogFramer(multiplexed: false, stream: .stdout, timestamps: false)
        #expect(String(buffer: plain.frame(Data("one\ntw".utf8), at: time)) == "one\ntw")
    }

    @Test("framing: multiplexed under the asked stream, raw for a terminal")
    func framing() throws {
        var multiplexed = DockerLogFramer(multiplexed: true, stream: .stdout, timestamps: false)
        let framed = multiplexed.frame(Data("hi\n".utf8), at: Date())
        #expect(Array(framed.readableBytesView) == [1, 0, 0, 0, 0, 0, 0, 3] + Array("hi\n".utf8))
        var errors = DockerLogFramer(multiplexed: true, stream: .stderr, timestamps: false)
        #expect(errors.frame(Data("x".utf8), at: Date()).readableBytesView.first == 2)
        var raw = DockerLogFramer(multiplexed: false, stream: .stdout, timestamps: false)
        #expect(String(buffer: raw.frame(Data("hi\n".utf8), at: Date())) == "hi\n")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LogRouteTests {
    @Test("logs of a container without a tty are framed as stdout, with tail; of one with a tty, raw")
    func framedAndRaw() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("a\nb\nc\n")
        let framed = try await h.request("GET", "/containers/box/logs?stdout=1&stderr=1&tail=2")
        #expect(framed.status == 200)
        #expect(framed.header("Content-Type") == "application/vnd.docker.multiplexed-stream")
        let streams = try ToolHarness.demux(framed.body)
        #expect(streams.stdout == "b\nc\n")
        #expect(streams.stderr == "")
        let raw = try await h.request("GET", "/containers/term/logs?stdout=1&tail=all")
        #expect(raw.header("Content-Type") == "application/vnd.docker.raw-stream")
        #expect(raw.text == "a\nb\nc\n")
        // Only stderr asked for: the same output, under stderr.
        let stderrOnly = try ToolHarness.demux(try await h.request("GET", "/containers/box/logs?stderr=1").body)
        #expect(stderrOnly.stderr == "a\nb\nc\n" && stderrOnly.stdout == "")
    }

    @Test("logs without a stream is dockerd's 400, and a missing container a 404")
    func refusals() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let none = try await h.request("GET", "/containers/box/logs")
        #expect(none.status == 400)
        #expect(try none.json()["message"] as? String == "must specify at least one of 'stdout' or 'stderr'")
        #expect(try await h.request("GET", "/containers/ghost/logs?stdout=1").status == 404)
    }

    @Test("follow sends what is written later, and ends once the container has stopped")
    func follow() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("old\n")
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1&tail=0 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            try h.tools.appendLog("new line\n")
            #expect(try await client.read(through: "new line\n").hasSuffix("new line\n"))
            try h.tools.appendLog("last words\n")
            h.tools.base.update(String(ToolHarness.ttyID.prefix(12))) { $0.status = .stopped }
            // The rest of the chunked body, framing and all: the stream ends rather than hangs.
            let rest = String(decoding: try await ToolHarness.readAll(client), as: UTF8.self)
            // What it wrote before it stopped still comes, and then the stream ends.
            #expect(rest.contains("last words\n"))
            #expect(!rest.contains("old"))
        }
    }

    @Test("follow ends at the exit when the container restarts, as dockerd's does, after what it wrote last", arguments: [true, false])
    func followEndsAtRestart(waitingToRestart: Bool) async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1&tail=0 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            try h.tools.appendLog("first run\n")
            #expect(try await client.read(through: "first run\n").hasSuffix("first run\n"))
            try h.tools.appendLog("last words\n")
            // The policy's restart: waiting out its delay, or already running again.
            h.tools.base.update(String(ToolHarness.ttyID.prefix(12))) {
                if waitingToRestart {
                    $0.status = .restarting
                } else {
                    $0.startedDate = Fixtures.now
                }
            }
            let rest = String(decoding: try await ToolHarness.readAll(client), as: UTF8.self)
            #expect(rest.contains("last words\n"))
        }
    }

    @Test("follow of a container waiting to restart sends its log and ends, as dockerd does for one not running")
    func followOfRestartingContainerEnds() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("from the last run\n")
        h.tools.base.update(String(ToolHarness.ttyID.prefix(12))) { $0.status = .restarting }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            let answer = String(decoding: try await ToolHarness.readAll(client), as: UTF8.self)
            #expect(answer.hasPrefix("HTTP/1.1 200 OK"))
            #expect(answer.contains("from the last run\n"))
        }
    }

    @Test("follow ends at once when the log is deleted with its container, after what was left in it")
    func followEndsWhenDeleted() async throws {
        // The container is not asked about for an hour: only the deletion can end this follow.
        let options = DockerToolOptions(logPollInterval: .milliseconds(20), logStatusInterval: .seconds(3600), statsInterval: .milliseconds(50))
        let h = try await ToolHarness.start(options: options)
        defer { Task { try? await h.stop() } }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1&tail=0 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            try h.tools.appendLog("running\n")
            #expect(try await client.read(through: "running\n").hasSuffix("running\n"))
            try h.tools.appendLog("final\n")
            try FileManager.default.removeItem(at: h.tools.logFile)
            let rest = String(decoding: try await ToolHarness.readAll(client), as: UTF8.self)
            #expect(rest.contains("final\n"))
        }
    }

    @Test("follow does not send the log the next run rewrote, and does send a rollover in the run")
    func followStopsAtNextRunsLog() async throws {
        // The container is not asked about for an hour unless the file is rewritten.
        let options = DockerToolOptions(logPollInterval: .milliseconds(20), logStatusInterval: .seconds(3600), statsInterval: .milliseconds(50))
        let h = try await ToolHarness.start(options: options)
        defer { Task { try? await h.stop() } }
        func rewrite(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: h.tools.logFile)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
        }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1&tail=0 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            try h.tools.appendLog("first run\n")
            #expect(try await client.read(through: "first run\n").hasSuffix("first run\n"))
            // Control: the engine's rollover of a full log, in the same run, is sent on.
            try rewrite("[container log rolled over]\nrolled\n")
            #expect(try await client.read(through: "rolled\n").hasSuffix("rolled\n"))
            // The restart: a new run, which starts the log again.
            h.tools.base.update(String(ToolHarness.ttyID.prefix(12))) { $0.startedDate = Fixtures.now }
            try rewrite("second run\n")
            let rest = String(decoding: try await ToolHarness.readAll(client), as: UTF8.self)
            #expect(!rest.contains("second run"))
        }
    }

    @Test("a followed log stops looking for a client that has gone")
    func followReleasedOnDisconnect() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/term/logs?stdout=1&follow=1 HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            let connected = h.tools.getCount
            // Control: while the client is there, the container keeps being looked at.
            #expect(await StreamHarness.eventually { h.tools.getCount > connected + 1 })
        }
        try await Task.sleep(for: .milliseconds(150))
        let gone = h.tools.getCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.tools.getCount == gone)
    }

    @Test("an attach to a running container without stdin follows its output from the log, as docker-java asks it, until it stops")
    func attachToRunningOutput() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("before\n")
        try await h.server.withClient { client in
            // docker-java's attach with no stdin: no Upgrade header, every flag as true.
            try await client.send(
                "POST /v1.48/containers/box/attach?logs=false&stdout=true&stderr=true&stream=true HTTP/1.1\r\nHost: d\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"
            )
            let head = try await client.read(through: "\r\n\r\n")
            #expect(head.hasPrefix("HTTP/1.1 200 OK"))
            #expect(head.contains("application/vnd.docker.multiplexed-stream"))
            try h.tools.appendLog("after\n")
            try await Task.sleep(for: .milliseconds(100))
            h.tools.base.update(String(ToolHarness.boxID.prefix(12))) { $0.status = .stopped }
            let framed = Array(try await ToolHarness.readAll(client))
            // From the attach on, framed as stdout; then the end, once the container stopped.
            #expect(framed == [1, 0, 0, 0, 0, 0, 0, 6] + Array("after\n".utf8))
        }
    }

    @Test("an attach to a running container replays its log with logs=1, and with stream=0 ends after it")
    func attachReplaysLog() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("one\ntwo\n")
        let past = try await h.request("POST", "/containers/term/attach?logs=1&stdout=1&stream=0")
        #expect(past.status == 200)
        // A terminal's output is raw.
        #expect(past.text == "one\ntwo\n")
        // Control: without logs, nothing of the past.
        #expect(try await h.request("POST", "/containers/term/attach?stdout=1&stream=0").text == "")
        // A container that never ran has no past to replay, and no log to ask for.
        h.tools.base.update(String(ToolHarness.stoppedID.prefix(12))) {
            $0.startedDate = nil
            $0.exitCode = nil
            $0.exitedAt = nil
        }
        let created = try await h.request("POST", "/containers/off/attach?logs=1&stdout=1&stream=0")
        #expect(created.status == 200)
        #expect(created.text == "")
    }

    @Test("an attach to a running container that asks for stdin is still refused, and says how to attach to its output")
    func attachToRunningWithStdin() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let refused = try await h.request("POST", "/containers/box/attach?stream=1&stdin=1&stdout=1")
        #expect(refused.status == 409)
        #expect((try refused.json()["message"] as? String)?.contains("attach to its output alone") == true)
    }

    @Test("without follow, the answer ends at what was there, however much is written after")
    func noFollowEnds() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try h.tools.appendLog("one\n")
        let answer = try await h.request("GET", "/containers/term/logs?stdout=1")
        #expect(answer.text == "one\n")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StatsTests {
    static func stats(cpuMicros: UInt64, memory: UInt64 = 5 << 20, limit: UInt64? = nil, network: Bool = true) -> ContainerStats {
        ContainerStats(
            id: "c", memoryUsageBytes: memory, memoryLimitBytes: limit, cpuUsageUsec: cpuMicros, networkRxBytes: network ? 100 : nil,
            networkTxBytes: network ? 50 : nil, blockReadBytes: 4096, blockWriteBytes: nil, numProcesses: 3)
    }

    static let container = DockerContainer(snapshot: Fixtures.dockerContainer(name: "box", dockerID: ToolHarness.boxID), dockerID: ToolHarness.boxID, name: "box")

    @Test("the engine's numbers land where the CLI reads them")
    func mapping() throws {
        let read = Fixtures.now
        let sample = DockerStatsSample(stats: Self.stats(cpuMicros: 2_000_000), read: read, systemNanoseconds: 40_000_000_000, cpus: 4)
        let stats = DockerStatsMapper.map(sample, previous: nil, container: Self.container)
        #expect(stats.id == ToolHarness.boxID)
        #expect(stats.name == "/box")
        #expect(stats.cpu_stats.cpu_usage.total_usage == 2_000_000_000)
        #expect(stats.cpu_stats.system_cpu_usage == 40_000_000_000)
        #expect(stats.cpu_stats.online_cpus == 4)
        #expect(stats.memory_stats.usage == 5 << 20)
        // No limit from the engine: the container's configured memory.
        #expect(stats.memory_stats.limit == Self.container.snapshot.configuration.resources.memoryInBytes)
        #expect(stats.networks?["eth0"]?.rx_bytes == 100 && stats.networks?["eth0"]?.tx_bytes == 50)
        #expect(stats.blkio_stats.io_service_bytes_recursive?.map(\.op) == ["read", "write"])
        #expect(stats.blkio_stats.io_service_bytes_recursive?.first?.value == 4096)
        #expect(stats.pids_stats.current == 3)
        #expect(stats.preread == ContainerViewMapper.zeroTime)
        // The first sample has no previous one: an empty precpu, as dockerd sends.
        #expect(stats.precpu_stats.system_cpu_usage == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: try DockerJSON.encoder.encode(stats)) as? [String: Any])
        let precpu = try #require(json["precpu_stats"] as? [String: Any])
        #expect((precpu["cpu_usage"] as? [String: Any])?["total_usage"] as? Int == 0)
        #expect(precpu["system_cpu_usage"] == nil)
        // Control: no network numbers, no networks object.
        let quiet = DockerStatsMapper.map(
            DockerStatsSample(stats: Self.stats(cpuMicros: 0, network: false), read: read, systemNanoseconds: 1, cpus: 1), previous: nil,
            container: Self.container)
        #expect(quiet.networks == nil)
    }

    @Test("the CLI's CPU percentage comes out per CPU: one CPU busy is 100%, two of four are 200%")
    func cpuPercent() {
        // One second of wall time on a 4-CPU VM: the system clock advances 4 s.
        let first = DockerStatsSample(stats: Self.stats(cpuMicros: 1_000_000), read: Fixtures.now, systemNanoseconds: 10_000_000_000 * 4, cpus: 4)
        let oneBusy = DockerStatsSample(
            stats: Self.stats(cpuMicros: 2_000_000), read: Fixtures.now.addingTimeInterval(1), systemNanoseconds: 11_000_000_000 * 4, cpus: 4)
        #expect(abs(DockerStatsMapper.cpuPercent(DockerStatsMapper.map(oneBusy, previous: first, container: Self.container)) - 100) < 0.001)
        let twoBusy = DockerStatsSample(
            stats: Self.stats(cpuMicros: 3_000_000), read: Fixtures.now.addingTimeInterval(1), systemNanoseconds: 11_000_000_000 * 4, cpus: 4)
        #expect(abs(DockerStatsMapper.cpuPercent(DockerStatsMapper.map(twoBusy, previous: first, container: Self.container)) - 200) < 0.001)
        // Control: no time passed between the two samples, so nothing to divide by: 0.
        #expect(DockerStatsMapper.cpuPercent(DockerStatsMapper.map(oneBusy, previous: oneBusy, container: Self.container)) == 0)
    }

    @Test("stream=0 answers one object with a previous sample, one-shot without, and a stopped container zeros")
    func oneObject() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.samples = [Self.stats(cpuMicros: 1000), Self.stats(cpuMicros: 3000)]
        let two = try await h.request("GET", "/containers/box/stats?stream=0").json()
        #expect((two["cpu_stats"] as? [String: Any]).flatMap { ($0["cpu_usage"] as? [String: Any])?["total_usage"] as? Int } == 3_000_000)
        #expect((two["precpu_stats"] as? [String: Any]).flatMap { ($0["cpu_usage"] as? [String: Any])?["total_usage"] as? Int } == 1_000_000)
        #expect(two["preread"] as? String != ContainerViewMapper.zeroTime)
        let one = try await h.request("GET", "/containers/box/stats?stream=0&one-shot=1").json()
        #expect(one["preread"] as? String == ContainerViewMapper.zeroTime)
        let stopped = try await h.request("GET", "/containers/off/stats?stream=0").json()
        #expect(stopped["name"] as? String == "/off")
        #expect(stopped["read"] as? String == ContainerViewMapper.zeroTime)
    }

    @Test("a stats stream stops sampling for a client that has gone")
    func streamReleasedOnDisconnect() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.samples = [Self.stats(cpuMicros: 1)]
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/box/stats HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "}\n")
            let connected = h.tools.statsCount
            // Control: while the client is there, samples keep coming.
            #expect(await StreamHarness.eventually { h.tools.statsCount > connected + 1 })
        }
        try await Task.sleep(for: .milliseconds(150))
        let gone = h.tools.statsCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.tools.statsCount == gone)
    }

    @Test("a stream sends a sample each interval, each with the one before as precpu, and ends when the container stops")
    func stream() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.samples = (1...50).map { Self.stats(cpuMicros: UInt64($0) * 1000) }
        try await h.server.withClient { client in
            try await client.send("GET /v1.48/containers/box/stats HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n")
            _ = try await client.read(through: "\r\n\r\n")
            var lines: [[String: Any]] = []
            while lines.count < 3 {
                let line = try await client.read(through: "}\n")
                let start = try #require(line.firstIndex(of: "{"))
                lines.append(try #require(try JSONSerialization.jsonObject(with: Data(line[start...].utf8)) as? [String: Any]))
            }
            func total(_ object: [String: Any], _ key: String) -> Int? {
                ((object[key] as? [String: Any])?["cpu_usage"] as? [String: Any])?["total_usage"] as? Int
            }
            #expect(total(lines[0], "precpu_stats") == 0)
            #expect(total(lines[1], "precpu_stats") == total(lines[0], "cpu_stats"))
            #expect(total(lines[2], "precpu_stats") == total(lines[1], "cpu_stats"))
            h.tools.base.update(String(ToolHarness.boxID.prefix(12))) { $0.status = .stopped }
            _ = try await client.readToEnd()
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TopTests {
    @Test("ps output: titles from the first line, the last column taking the rest of the line")
    func parse() throws {
        let busybox = "PID   USER     TIME  COMMAND\n    1 root      0:00 sh -c while true; do sleep 1; done\n   12 root      0:00 ps -ef\n"
        let top = try DockerTopParser.parse(busybox)
        #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
        #expect(top.Processes == [["1", "root", "0:00", "sh -c while true; do sleep 1; done"], ["12", "root", "0:00", "ps -ef"]])
        let procps = "UID          PID    PPID  C STIME TTY          TIME CMD\nroot           1       0  0 10:00 ?        00:00:00 nginx: master process\n"
        #expect(try DockerTopParser.parse(procps).Processes == [["root", "1", "0", "0", "10:00", "?", "00:00:00", "nginx: master process"]])
    }

    @Test("ps output without a PID column is refused as dockerd refuses it")
    func noPID() {
        #expect(throws: DockerAPIError.internalError("Couldn't find PID field in ps output")) { try DockerTopParser.parse("USER COMMAND\nroot sh\n") }
    }

    @Test("top runs ps -ef in the container by default and the given arguments otherwise")
    func route() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let answer = try await h.request("GET", "/containers/box/top")
        #expect(answer.status == 200)
        #expect(try answer.json()["Titles"] as? [String] == ["PID", "USER", "TIME", "COMMAND"])
        #expect(h.tools.lastConfiguration?.executable == "ps")
        #expect(h.tools.lastConfiguration?.arguments == ["-ef"])
        _ = try await h.request("GET", "/containers/box/top?ps_args=aux")
        #expect(h.tools.lastConfiguration?.arguments == ["aux"])
    }

    @Test("a container without ps is a 500 that says so; a failing ps is dockerd's 'ps:' error; a stopped container a 409")
    func failures() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.available.remove("ps")
        let missing = try await h.request("GET", "/containers/box/top")
        #expect(missing.status == 500)
        #expect((try missing.json()["message"] as? String)?.contains("by running ps inside it") == true)
        h.tools.available.insert("ps")
        h.tools.psStatus = 1
        let failing = try await h.request("GET", "/containers/box/top?ps_args=-Z")
        #expect(failing.status == 500)
        #expect(try failing.json()["message"] as? String == "ps: ps: unrecognized option")
        #expect(try await h.request("GET", "/containers/off/top").status == 409)
    }
}
