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

import ContainerTestSupport
import Foundation
import Testing

/// Serial lifecycle tests that require non-warmup images or exclusive port binding.
@Suite(.serialized)
struct TestCLIRunLifecycleSerial {
    /// A fast probe repeatedly crosses guest setup while removal begins. Waiting for
    /// a running-probe marker would miss cancellation before its guest record exists.
    @Test func testTeardownDuringHealthProbeStartup() async throws {
        try await ContainerFixture.with { f in
            let label = "io.siliconship.test.health-start=\(UUID().uuidString)"
            for iteration in 0..<20 {
                let name = "\(f.testID)-health-start-\(iteration)"
                f.addCleanup { _ = try? f.run(["rm", "-f", "--require-label", label, name]).check() }
                try f.run([
                    "run", "-d", "--name", name, "--label", label, "--cpus", "1", "--memory", "512M",
                    "--health-cmd", "true", "--health-interval", "1ms", "--health-timeout", "2s",
                    "docker.io/library/alpine:3.22", "sleep", "300",
                ]).check()
                // Deliberately do not wait for a completed check before removing it.
                try f.run(["rm", "-f", "--require-label", label, name]).check()
                let remaining = try f.run(["ls", "-a", "-q"]).check()
                #expect(!remaining.output.split(whereSeparator: \.isNewline).contains(Substring(name)))
            }
        }
    }

    /// The marker proves the long probe has started before teardown. Stop must cancel
    /// and drain it, rather than wait for its minute-long timeout or race its deletion.
    @Test func testTeardownDuringActiveHealthProbe() async throws {
        try await ContainerFixture.with { f in
            let project = "\(f.testID)-health"
            let name = "\(project)-probe-1"
            let network = "\(project)-net"
            let volume = "\(project)-data"
            let label = "io.siliconship.test.health-shutdown=\(UUID().uuidString)"
            try f.run(["network", "create", "--label", label, network]).check()
            f.addCleanup { _ = try? f.run(["network", "rm", "--require-label", label, network]).check() }
            try f.run(["volume", "create", "--label", label, volume]).check()
            f.addCleanup { _ = try? f.run(["volume", "rm", "--require-label", label, volume]).check() }
            f.addCleanup { _ = try? f.run(["rm", "-f", "--require-label", label, name]).check() }

            func waitForProbe() async throws {
                let deadline = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < deadline {
                    if try f.run(["exec", name, "test", "-f", "/tmp/health-active"]).status == 0 { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw CommandError.executionFailed("the health probe never started; teardown was not exercised during a probe")
            }

            // Include start time with PID so reuse cannot make an old helper appear alive.
            // Prove the selector sees the running helper before relying on its absence.
            func runtimeRows() throws -> Set<String> {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-axo", "pid=,lstart=,command="]
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try #require(process.terminationStatus == 0, "runtime helper inventory failed")
                return Set(
                    String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).filter { row in
                        let fields = row.split(whereSeparator: \.isWhitespace)
                        guard let uuid = fields.firstIndex(of: "--uuid"), uuid + 1 < fields.count, fields[uuid + 1] == name else { return false }
                        return fields.contains { $0.hasSuffix("/container-runtime-linux") || $0 == "container-runtime-linux" }
                    }.map(String.init))
            }

            func waitForHelpersToExit(_ previous: Set<String>) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while !(try runtimeRows()).intersection(previous).isEmpty {
                    try #require(ContinuousClock.now < deadline, "a runtime helper survived health-check teardown")
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            for action in ["stop", "exit", "delete"] {
                for _ in 0..<3 {
                    try f.run([
                        "run", "-d", "--name", name, "--label", label, "--cpus", "1", "--memory", "512M",
                        "--network", network, "-v", "\(volume):/data",
                        "--health-cmd", "echo active > /tmp/health-active; sleep 300", "--health-interval", "100ms", "--health-timeout", "60s",
                        "docker.io/library/alpine:3.22", "/bin/sh", "-c", "trap 'exit 0' TERM; while [ ! -f /tmp/exit ]; do sleep 1; done",
                    ]).check()
                    try await waitForProbe()
                    var observedHelpers = try runtimeRows()
                    try #require(observedHelpers.count == 1, "the active probe's runtime helper was not observed")
                    try f.run(["exec", name, "sh", "-c", "printf '%s' '\(label)' > /data/marker"]).check()
                    var before = ContinuousClock.now
                    if action == "stop" {
                        // Remove the marker while the old probe sleeps: its recreation
                        // after start proves the new monitor actually runs a fresh probe.
                        try f.run(["exec", name, "rm", "/tmp/health-active"]).check()
                        try f.run(["stop", "-t", "1", name]).check()
                        #expect(try f.getContainerStatus(name) == "stopped")
                        #expect(before.duration(to: .now) < .seconds(10), "stop waited on the health timeout")
                        try await waitForHelpersToExit(observedHelpers)
                        try f.run(["start", name]).check()
                        try await waitForProbe()
                        let restarted = try runtimeRows()
                        try #require(restarted.count == 1 && restarted.isDisjoint(with: observedHelpers), "restart reused the old runtime helper")
                        observedHelpers.formUnion(restarted)
                        #expect(try f.run(["exec", name, "cat", "/data/marker"]).check().output == label, "restart lost workload data")
                        before = .now
                    } else if action == "exit" {
                        try f.run(["exec", name, "touch", "/tmp/exit"]).check()
                        let deadline = ContinuousClock.now + .seconds(10)
                        while try f.getContainerStatus(name) != "stopped", ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        try #require(try f.getContainerStatus(name) == "stopped", "natural exit did not finish health cleanup")
                    }
                    try f.run(["rm", "-f", "--require-label", label, name]).check()
                    #expect(before.duration(to: .now) < .seconds(10), "teardown waited on the health timeout")
                    try await waitForHelpersToExit(observedHelpers)
                    let listed = try f.run(["ls", "-a", "-q"]).check()
                    #expect(!listed.output.split(whereSeparator: \.isNewline).contains(Substring(name)), "deleted container remains")
                }
            }
            try f.run(["volume", "rm", "--require-label", label, volume]).check()
            try f.run(["network", "rm", "--require-label", label, network]).check()
        }
    }

    @Test func testStartPortBindFails() async throws {
        try await ContainerFixture.with { f in
            let port = UInt16.random(in: 50000..<60000)
            let serverImage = "docker.io/library/python:alpine"
            try f.run(["image", "pull", serverImage]).check()

            let name = "\(f.testID)-c"
            try f.doCreate(name: name, ports: ["\(port)"])
            f.addCleanup { try? f.doRemove(name) }

            let server = "\(f.testID)-server"
            try await f.doLongRun(
                name: server,
                image: serverImage,
                args: ["--publish", "\(port):\(port)"],
                containerArgs: ["python3", "-m", "http.server", "\(port)"])
            f.addCleanup { try? f.doStop(server) }

            let startResult = try f.run(["start", name])
            #expect(startResult.status != 0, "expected start to fail when port is already bound")

            let status = try f.getContainerStatus(name)
            #expect(status == "stopped")
        }
    }
}
