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
import ContainerizationExtras
import Foundation
import Testing

@testable import DockerAPIService

struct ContainerViewMapperTests {
    let context = DockerViewContext(now: Fixtures.now, builtinNetwork: Fixtures.builtin)

    private func container(_ snapshot: ContainerSnapshot, extras: DockerContainerExtras? = nil) -> DockerContainer {
        DockerContainer(snapshot: snapshot, dockerID: Fixtures.id("abc"), name: "web", extras: extras)
    }

    @Test("running is running, stopped after a run is exited, never run is created, restarting is restarting")
    func statuses() {
        let configuration = Fixtures.configuration(id: "c")
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .running)) == .running)
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .stopping)) == .running)
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .restarting, exitCode: 1)) == .restarting)
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .stopped, exitCode: 0)) == .exited)
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .stopped, started: nil, exitCode: 3)) == .exited)
        // Control: stopped with no sign of a run is only created.
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .stopped, started: nil)) == .created)
        #expect(ContainerViewMapper.status(Fixtures.snapshot(configuration, status: .unknown, started: nil)) == .created)
        #expect(ContainerViewMapper.isRunning(Fixtures.snapshot(configuration, status: .restarting)))
        #expect(!ContainerViewMapper.isRunning(Fixtures.snapshot(configuration, status: .stopped)))
    }

    @Test("the Status column reads as docker ps writes it")
    func statusText() {
        let configuration = Fixtures.configuration(id: "c")
        let now = Fixtures.now
        #expect(ContainerViewMapper.statusText(Fixtures.snapshot(configuration, started: now.addingTimeInterval(-300)), now: now) == "Up 5 minutes")
        var healthy = Fixtures.snapshot(configuration, started: now.addingTimeInterval(-30))
        healthy.health = ContainerHealth(status: .healthy)
        #expect(ContainerViewMapper.statusText(healthy, now: now) == "Up 30 seconds (healthy)")
        healthy.health = ContainerHealth(status: .starting)
        #expect(ContainerViewMapper.statusText(healthy, now: now) == "Up 30 seconds (health: starting)")
        let exited = Fixtures.snapshot(configuration, status: .stopped, exitCode: 137, exited: now.addingTimeInterval(-7200))
        #expect(ContainerViewMapper.statusText(exited, now: now) == "Exited (137) 2 hours ago")
        #expect(ContainerViewMapper.statusText(Fixtures.snapshot(configuration, status: .stopped, started: nil), now: now) == "Created")
        #expect(ContainerViewMapper.humanDuration(0.5) == "Less than a second")
        #expect(ContainerViewMapper.humanDuration(1) == "1 second")
        #expect(ContainerViewMapper.humanDuration(90) == "About a minute")
        #expect(ContainerViewMapper.humanDuration(3600) == "About an hour")
        #expect(ContainerViewMapper.humanDuration(3 * 86400) == "3 days")
        #expect(ContainerViewMapper.humanDuration(20 * 86400) == "2 weeks")
    }

    @Test("a summary names the container with a slash, shows the image as the client named it, and hides this service's labels")
    func summary() throws {
        var configuration = Fixtures.configuration(
            id: "abc000000000", labels: [DockerLabels.id: Fixtures.id("abc"), DockerLabels.name: "web", DockerLabels.image: "alpine", "app": "shop"])
        configuration.publishedPorts = [
            try PublishPort(hostAddress: try IPAddress("0.0.0.0"), hostPort: 8080, containerPort: 80, proto: .tcp, count: 2)
        ]
        let snapshot = Fixtures.snapshot(configuration, networks: [try Fixtures.attachment()])
        let extras = DockerContainerExtras(image: "alpine", imageID: Fixtures.configDigest, exposedPorts: ["80/tcp", "81/tcp", "9000/udp"])
        let summary = ContainerViewMapper.summary(container(snapshot, extras: extras), context: context)
        #expect(summary.Id == Fixtures.id("abc"))
        #expect(summary.Names == ["/web"])
        #expect(summary.Image == "alpine")
        #expect(summary.ImageID == Fixtures.configDigest)
        #expect(summary.Command == "/bin/sh -c sleep 1")
        #expect(summary.Created == Int64(Fixtures.now.addingTimeInterval(-600).timeIntervalSince1970))
        #expect(summary.Labels == ["app": "shop"])
        #expect(summary.State == "running")
        #expect(summary.Status == "Up 5 minutes")
        #expect(summary.HostConfig.NetworkMode == "bridge")
        #expect(summary.NetworkSettings.Networks.keys.sorted() == ["bridge"])
        #expect(summary.NetworkSettings.Networks["bridge"]?.IPAddress == "192.168.64.3")
        #expect(
            summary.Ports.map { "\($0.IP ?? "-"):\($0.PublicPort ?? 0)->\($0.PrivatePort)/\($0.type)" } == [
                "0.0.0.0:8080->80/tcp", "0.0.0.0:8081->81/tcp", "-:0->9000/udp",
            ])
        // Control: without extras, a foreign container's image is the engine's reference made familiar.
        let foreign = ContainerViewMapper.summary(container(Fixtures.snapshot(Fixtures.configuration(id: "x"))), context: context)
        #expect(foreign.Image == "alpine:latest")
        #expect(foreign.ImageID == Fixtures.imageDescription().digest)
    }

    @Test("inspect carries state, times, config and the bridge network's address at the top")
    func inspect() throws {
        var configuration = Fixtures.configuration(id: "abc000000000", labels: [DockerLabels.name: "web", "app": "shop"])
        configuration.mounts = [
            .virtiofs(source: "/Users/me/src", destination: "/src", options: ["ro"]),
            .tmpfs(destination: "/run", options: []),
        ]
        configuration.restartPolicy = .onFailure(maxRetries: 2)
        configuration.healthCheck = HealthCheckConfiguration(test: ["CMD", "true"], interval: 1_000_000_000)
        configuration.initProcess.terminal = true
        configuration.initProcess.user = .raw(userString: "nginx")
        let started = Date(timeIntervalSince1970: 1_799_999_000)
        let snapshot = Fixtures.snapshot(configuration, started: started, networks: [try Fixtures.attachment()])
        let extras = DockerContainerExtras(
            image: "alpine", imageID: Fixtures.configDigest, entrypoint: nil, cmd: ["/bin/sh"], attachStdin: true, openStdin: true, stdinOnce: true,
            autoRemove: true)
        let inspect = ContainerViewMapper.inspect(container(snapshot, extras: extras), context: context)
        #expect(inspect.Id == Fixtures.id("abc"))
        #expect(inspect.Name == "/web")
        #expect(inspect.Path == "/bin/sh")
        #expect(inspect.Args == ["-c", "sleep 1"])
        #expect(inspect.Image == Fixtures.configDigest)
        #expect(inspect.State.Status == "running")
        #expect(inspect.State.Running)
        #expect(inspect.State.StartedAt == "2027-01-15T07:43:20.000Z")
        #expect(inspect.State.FinishedAt == ContainerViewMapper.zeroTime)
        #expect(inspect.Config.Cmd == ["/bin/sh"])
        #expect(inspect.Config.Entrypoint == nil)
        #expect(inspect.Config.Tty)
        #expect(inspect.Config.OpenStdin && inspect.Config.StdinOnce && inspect.Config.AttachStdin)
        #expect(inspect.Config.User == "nginx")
        #expect(inspect.Config.Image == "alpine")
        #expect(inspect.Config.Labels == ["app": "shop"])
        #expect(inspect.Config.Hostname == "abc000000000")
        #expect(inspect.Config.Healthcheck?.Test == ["CMD", "true"])
        #expect(inspect.HostConfig.AutoRemove)
        #expect(inspect.HostConfig.RestartPolicy == DockerRestartPolicy(Name: "on-failure", MaximumRetryCount: 2))
        #expect(inspect.HostConfig.Binds == ["/Users/me/src:/src:ro"])
        #expect(inspect.HostConfig.NanoCpus == 4_000_000_000)
        #expect(inspect.Mounts.map(\.type) == ["bind", "tmpfs"])
        #expect(inspect.Mounts.first?.RW == false)
        #expect(inspect.NetworkSettings.IPAddress == "192.168.64.3")
        #expect(inspect.NetworkSettings.IPPrefixLen == 24)
        #expect(inspect.NetworkSettings.Gateway == "192.168.64.1")
        #expect(inspect.NetworkSettings.Networks["bridge"]?.NetworkID == Fixtures.builtin)
    }

    @Test("an exited container shows its exit and when it finished; one on another network has no top-level address")
    func inspectExited() throws {
        var configuration = Fixtures.configuration(id: "x")
        configuration.networks = [AttachmentConfiguration(network: "shop", options: AttachmentOptions(hostname: "x"))]
        let exited = Fixtures.now.addingTimeInterval(-60)
        let snapshot = Fixtures.snapshot(configuration, status: .stopped, exitCode: 2, exited: exited)
        let inspect = ContainerViewMapper.inspect(container(snapshot), context: context)
        #expect(inspect.State.Status == "exited")
        #expect(!inspect.State.Running)
        #expect(inspect.State.ExitCode == 2)
        #expect(inspect.State.FinishedAt == ContainerViewMapper.timestamp(exited))
        #expect(inspect.NetworkSettings.IPAddress == "")
        #expect(inspect.NetworkSettings.Networks.keys.sorted() == ["shop"])
        // Control: without extras the command is the engine's, whole.
        #expect(inspect.Config.Cmd == ["/bin/sh", "-c", "sleep 1"])
        #expect(inspect.HostConfig.AutoRemove == false)
    }

    @Test("the inspect JSON uses Docker's field names")
    func wireNames() throws {
        let snapshot = Fixtures.snapshot(Fixtures.configuration(id: "x"))
        let data = try JSONEncoder().encode(ContainerViewMapper.inspect(container(snapshot), context: context))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["Id"] as? String == Fixtures.id("abc"))
        #expect((object["State"] as? [String: Any])?["Status"] as? String == "running")
        #expect((object["NetworkSettings"] as? [String: Any])?["Networks"] != nil)
        #expect(object["id"] == nil)
    }
}
