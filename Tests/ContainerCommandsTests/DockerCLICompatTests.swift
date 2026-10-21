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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import DockerAPIService
import Foundation
import Testing

@testable import ContainerCommands

/// The Docker CLI syntax VS Code Dev Containers sends when `dev.containers.dockerPath` is
/// `container` (#619), each piece where `container`'s own syntax does not have it.
struct DockerCLICompatTests {
    private func parse<Command: ParsableCommand>(_ arguments: [String], as type: Command.Type = Command.self) throws -> Command {
        try #require(try Application.parseAsRoot(arguments) as? Command, "\(arguments) did not parse as \(Command.self)")
    }

    // MARK: -v

    @Test("-v alone is --version, in a line Dev Containers reads as Docker's")
    func dashV() throws {
        let line = try #require(Application.dockerVersionFlag(["-v"]))
        #expect(line == Application.configuration.version)
        // The extension and the spec CLI take a line naming podman or wslc for those CLIs.
        #expect(!line.lowercased().contains("podman"))
        #expect(!line.lowercased().contains("wslc"))
        #expect(line.hasPrefix("container CLI version "))
        // Anywhere else -v belongs to the command.
        #expect(Application.dockerVersionFlag(["run", "-v", "/a:/b", "alpine"]) == nil)
        #expect(Application.dockerVersionFlag(["-v", "x"]) == nil)
        #expect(Application.dockerVersionFlag([]) == nil)
    }

    // MARK: version --format

    @Test("version --format takes Docker templates; its own formats are unchanged")
    func versionFormat() throws {
        let template: Application.SystemVersion = try parse(["system", "version", "--format", "{{json .}}"])
        #expect(try template.format.dockerTemplate() != nil)
        let root: Application.Version = try parse(["version", "--format", "{{.Server.Version}}"])
        #expect(try root.command.format.dockerTemplate() != nil)
        for name in ListFormat.allCases.map(\.rawValue) {
            let own: Application.SystemVersion = try parse(["system", "version", "--format", name])
            guard case .format(let format) = own.format else {
                Issue.record("\(name) is not a format")
                continue
            }
            #expect(format.rawValue == name)
        }
        let plain: Application.SystemVersion = try parse(["system", "version"])
        guard case .format(.table) = plain.format else {
            Issue.record("the default is not table")
            return
        }
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["version", "--format", "xml"]) }
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["version", "--format", "{{range .}}{{end}}"]) }
    }

    @Test("the version report carries the Docker API's versions: an ApiVersion of at least 1.35 and Docker's release")
    func versionReport() throws {
        let report = DockerVersionReport(
            Client: .init(version: "1.6.0", commit: "abc"),
            Server: SystemRoutes.VersionBody(engineVersion: "1.6.0", engineCommit: "abc"))
        let json = try DockerTemplate("{{json .}}").render(report)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let server = try #require(object["Server"] as? [String: Any])
        let apiVersionText = try #require(server["ApiVersion"] as? String)
        let apiVersion = try #require(DockerAPIVersion(apiVersionText))
        // The extension refuses an engine below 1.35.
        #expect(apiVersion >= DockerAPIVersion(major: 1, minor: 35))
        #expect(apiVersion == DockerAPIVersion.current)
        #expect(server["Version"] as? String == DockerAPIVersion.dockerRelease)
        #expect(try DockerTemplate("{{.Server.Version}}").render(report) == DockerAPIVersion.dockerRelease)
        #expect(try DockerTemplate("{{.Server.ApiVersion}}").render(report) == "1.48")
        #expect(try DockerTemplate("{{.Client.Version}}").render(report) == "1.6.0")
        // The same body the Docker API agent answers `/version` with.
        let agent = try JSONEncoder().encode(SystemRoutes.VersionBody(engineVersion: "1.6.0", engineCommit: "abc"))
        #expect(try DockerTemplate("{{json .Server}}").render(report) == (try DockerTemplate.json(JSONSerialization.jsonObject(with: agent))))
    }

    // MARK: Templates

    @Test("templates print fields, json of any part, and trim around dashes")
    func templates() throws {
        struct Value: Encodable {
            struct Inner: Encodable {
                let Name: String
                let Count: Int
                let On: Bool
                let List: [String]
                let Map: [String: String]
            }
            let Inner: Inner
            let Top: String
        }
        let value = Value(Inner: .init(Name: "n", Count: 3, On: true, List: ["a", "b"], Map: ["k": "v", "a": "b"]), Top: "t")
        #expect(try DockerTemplate("{{.Top}}").render(value) == "t")
        #expect(try DockerTemplate("{{ .Inner.Name }}/{{.Inner.Count}}/{{.Inner.On}}").render(value) == "n/3/true")
        #expect(try DockerTemplate("{{.Inner.List}} {{.Inner.Map}}").render(value) == "[a b] map[a:b k:v]")
        #expect(try DockerTemplate("{{json .Inner.List}}").render(value) == #"["a","b"]"#)
        #expect(try DockerTemplate("{{json .Inner.Map}}").render(value) == #"{"a":"b","k":"v"}"#)
        #expect(try DockerTemplate("{{json .Top}}").render(value) == #""t""#)
        #expect(try DockerTemplate("{{.Missing}}").render(value) == "<no value>")
        #expect(try DockerTemplate("a  {{- .Top -}}  b").render(value) == "atb")
        #expect(try DockerTemplate("plain").render(value) == "plain")
        let whole = try DockerTemplate("{{json .}}").render(value)
        #expect(try JSONSerialization.jsonObject(with: Data(whole.utf8)) is [String: Any])
        #expect(!whole.contains("\n"))
    }

    @Test("what the template subset does not have is refused, not printed wrong")
    func templateRefusals() {
        for source in ["{{range .}}{{end}}", "{{.A | upper}}", "{{index .Labels \"k\"}}", "{{.A", "{{Top}}", "{{.A..B}}", "{{json}}"] {
            #expect(throws: DockerTemplateError.self, "\(source)") { try DockerTemplate(source) }
        }
        #expect(DockerTemplate.isTemplate("{{json .}}"))
        #expect(!DockerTemplate.isTemplate("json"))
    }

    // MARK: inspect

    @Test("inspect takes --type and --format; without them it is container's own")
    func inspectParses() throws {
        let image: Application.ContainerInspect = try parse(["inspect", "--type", "image", "alpine:3.20"])
        #expect(image.type == .image)
        #expect(image.containerIds == ["alpine:3.20"])
        let containers: Application.ContainerInspect = try parse(["inspect", "--type", "container", "a", "b"])
        #expect(containers.type == .container)
        let formatted: Application.ContainerInspect = try parse(["inspect", "-f", "{{.State.Status}}", "a"])
        #expect(try formatted.dockerTemplate() != nil)
        let json: Application.ContainerInspect = try parse(["inspect", "--format", "json", "a"])
        #expect(try json.dockerTemplate() == nil)
        let native: Application.ContainerInspect = try parse(["inspect", "a"])
        #expect(native.type == nil && native.format == nil)
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["inspect", "--type", "network", "a"]) }
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["inspect", "--format", "table", "a"]) }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func snapshot(id: String, labels: [String: String] = [:], status: RuntimeStatus = .running) throws -> ContainerSnapshot {
        var configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: "docker.io/library/alpine:3.20",
                descriptor: .init(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:" + String(repeating: "d", count: 64), size: 1)),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: ["-c", "sleep 1"], environment: ["PATH=/bin", "A=b"]))
        configuration.labels = labels
        configuration.creationDate = now.addingTimeInterval(-60)
        configuration.mounts = [.virtiofs(source: "/Users/me/project", destination: "/workspaces/project", options: [])]
        return ContainerSnapshot(configuration: configuration, status: status, networks: [], startedDate: now.addingTimeInterval(-30))
    }

    @Test("a container's Docker view has the fields Dev Containers reads, under its ID here")
    func containerView() throws {
        let labels = ["devcontainer.local_folder": "/Users/me/project", "devcontainer.config_file": "/Users/me/project/.devcontainer/devcontainer.json"]
        let views = DockerInspection.views([try Self.snapshot(id: "brave_web", labels: labels)], context: DockerViewContext(now: Self.now, builtinNetwork: nil))
        let view = try #require(views["brave_web"])
        // Fed back into `container exec`, `rm -f` and `start`: it must be the ID they take.
        #expect(view.Id == "brave_web")
        #expect(view.Name == "/brave_web")
        #expect(view.State.Status == "running")
        #expect(view.State.StartedAt != ContainerViewMapper.zeroTime)
        #expect(view.Config.Image == "alpine:3.20")
        #expect(view.Config.Labels == labels)
        #expect(view.Config.Env == ["PATH=/bin", "A=b"])
        #expect(view.Mounts.map(\.type) == ["bind"])
        #expect(view.Mounts.first?.Destination == "/workspaces/project")
        let json = try DockerInspection.render([.init(value: view)], template: nil)
        let array = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let ports = (array.first?["NetworkSettings"] as? [String: Any])?["Ports"]
        // The spec CLI reads `NetworkSettings.Ports` as an object, which must be there.
        #expect(ports is [String: Any])
        #expect(try DockerInspection.render([.init(value: view), .init(value: view)], template: DockerTemplate("{{.State.Status}}")) == "running\nrunning")
    }

    @Test("a container is found by ID, by name, then by a prefix of one ID only")
    func containerLookup() throws {
        let snapshots = [try Self.snapshot(id: "web-1"), try Self.snapshot(id: "web-2"), try Self.snapshot(id: "db", labels: ["com.siliconship.docker.name": "store"])]
        let views = DockerInspection.views(snapshots, context: DockerViewContext(now: Self.now, builtinNetwork: nil))
        #expect(DockerInspection.container("web-1", in: views)?.Id == "web-1")
        #expect(DockerInspection.container("d", in: views)?.Id == "db")
        #expect(DockerInspection.container("web", in: views) == nil, "two IDs begin with it")
        #expect(DockerInspection.container("nothing", in: views) == nil)
        #expect(DockerInspection.notFound("x", type: .image) == "No such image: x")
        #expect(DockerInspection.notFound("x", type: nil) == "No such object: x")
    }

    // MARK: run

    @Test("run takes Dev Containers' argv: -a stream names attach, --sig-proxy=false, consistency on a bind")
    func devContainersRun() throws {
        let arguments = [
            "run", "--sig-proxy=false", "-a", "STDOUT", "-a", "STDERR",
            "--mount", "type=bind,source=/Users/me/p,target=/workspaces/p,consistency=cached",
            "-l", "devcontainer.local_folder=/Users/me/p", "--entrypoint", "/bin/sh", "alpine:3.20",
            "-c", "echo Container started\ntrap \"exit 0\" 15\nexec \"$@\"\nwhile sleep 1 & wait $!; do :; done", "-",
        ]
        let run: Application.ContainerRun = try parse(arguments)
        #expect(run.sigProxy == DockerBool(false))
        #expect(try run.managementFlags.attachStreams == [.stdout, .stderr])
        // Neither stream is an arch: the host's stays.
        #expect(run.managementFlags.arch == Arch.hostArchitecture().rawValue)
        #expect(run.image == "alpine:3.20")
        #expect(run.arguments.first == "-c")
        #expect(run.arguments.last == "-")
    }

    @Test("-a with anything but a stream is still --arch")
    func dashAIsStillArch() throws {
        let arm: Application.ContainerRun = try parse(["run", "-a", "arm64", "alpine"])
        #expect(arm.managementFlags.arch == "arm64")
        #expect(try arm.managementFlags.attachStreams.isEmpty)
        let both: Application.ContainerRun = try parse(["run", "-a", "amd64", "-a", "stdin", "--arch", "arm64", "alpine"])
        #expect(both.managementFlags.arch == "arm64", "the last arch, as before")
        #expect(try both.managementFlags.attachStreams == [.stdin])
        let created: Application.ContainerCreate = try parse(["create", "--arch", "amd64", "alpine"])
        #expect(created.managementFlags.arch == "amd64")
        let plain: Application.ContainerRun = try parse(["run", "alpine"])
        #expect(plain.managementFlags.arch == Arch.hostArchitecture().rawValue)
        #expect(try plain.managementFlags.attachStreams.isEmpty)
    }

    @Test("--attach names streams; anything else is refused, and so is attaching a detached run")
    func attach() throws {
        let run: Application.ContainerRun = try parse(["run", "--attach", "Stdout", "alpine"])
        #expect(try run.managementFlags.attachStreams == [.stdout])
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["run", "--attach", "stdlog", "alpine"]) }
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["run", "-d", "-a", "stdout", "alpine"]) }
    }

    @Test("--sig-proxy is a flag, or takes a value after =; the image after it stays the image")
    func sigProxy() throws {
        let bare: Application.ContainerRun = try parse(["run", "--sig-proxy", "alpine", "sh"])
        #expect(bare.sigProxy == DockerBool(true))
        #expect(bare.image == "alpine")
        #expect(bare.arguments == ["sh"])
        let off: Application.ContainerRun = try parse(["run", "--sig-proxy=0", "alpine"])
        #expect(off.sigProxy == DockerBool(false))
        let unset: Application.ContainerRun = try parse(["run", "alpine"])
        #expect(unset.sigProxy == nil)
    }

    @Test("the launcher's terminal probe parses Dev Containers' run and exec argv")
    func terminalProbe() async throws {
        let run = ["run", "--sig-proxy=false", "-a", "STDOUT", "-a", "STDERR", "--mount", "type=bind,source=/a,target=/b,consistency=cached", "alpine"]
        // Parsed (the probe answers none for argv it cannot parse as well, so this is the check).
        _ = try parse(run, as: Application.ContainerRun.self)
        #expect(await Application.terminalMode(arguments: run) == "none")
        #expect(await Application.terminalMode(arguments: ["run", "-i", "-t", "--sig-proxy=false", "-a", "STDIN", "-a", "STDOUT", "alpine"]) == "raw")
        #expect(await Application.terminalMode(arguments: ["exec", "-i", "-t", "-u", "root", "-e", "A=b", "-w", "/", "web", "/bin/sh"]) == "raw")
    }

    // MARK: events

    @Test("events takes Docker's filters and formats")
    func eventsParse() throws {
        let events: Application.ContainerEvents = try parse([
            "events", "--format", "{{json .}}", "--filter", "event=start", "--filter", "label=devcontainer.local_folder=/a=b", "-f", "type=container",
        ])
        let filter = try events.eventFilter()
        let start = DockerEvent(
            type: "container", action: "start", actorID: "web", attributes: ["devcontainer.local_folder": "/a=b", "name": "web"], time: Self.now)
        #expect(filter.includes(start))
        var die = start
        die.action = "die"
        #expect(!filter.includes(die))
        var other = start
        other.attributes["devcontainer.local_folder"] = "/c"
        #expect(!filter.includes(other))
        let eventTemplate = try #require(try events.template())
        let line = try eventTemplate.render(start.message)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        // What the spec CLI matches on: the action (status before Docker 29), the ID and the labels.
        #expect(object["status"] as? String == "start")
        #expect(object["Action"] as? String == "start")
        #expect(object["id"] as? String == "web")
        #expect((object["Actor"] as? [String: Any])?["Attributes"] as? [String: String] == start.attributes)

        let byID: Application.ContainerEvents = try parse(["events", "--filter", "container=web"])
        #expect(try byID.eventFilter().includes(start))
        #expect(try byID.template() == nil)
        let json: Application.ContainerEvents = try parse(["events", "--format", "json"])
        #expect(try json.template() == DockerTemplate("{{json .}}"))
        for bad in [["events", "--filter", "nonsense"], ["events", "--filter", "colour=red"], ["events", "--format", "table"]] {
            #expect(throws: (any Error).self, "\(bad)") { try Application.parseAsRoot(bad) }
        }
        #expect(
            Application.ContainerEvents.text(start, timeZone: TimeZone(identifier: "UTC")!)
                == "2027-01-15T08:00:00.000Z container start web (devcontainer.local_folder=/a=b, name=web)")
    }

    // MARK: Docker Desktop

    /// With /Applications/Docker.app present, the extension launches Docker Desktop when a
    /// command's output has one of these (its `TV` check), so no text of this engine may.
    static let dockerDesktopTriggers = [
        "cannot connect to the docker daemon", "docker daemon is not running", "internal server error for api route and version",
        "activate the wsl integration", "failed to connect to the docker api",
    ]

    @Test("no text of this engine has a phrase that makes Dev Containers launch Docker Desktop")
    func noDockerDesktopTriggers() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            scanned += 1
            for phrase in Self.dockerDesktopTriggers {
                #expect(!text.contains(phrase), "\(file.path) has \"\(phrase)\"")
            }
        }
        #expect(scanned > 100)
        // The messages written for these commands' failures.
        let messages = [
            DockerInspection.notFound("x", type: .container), DockerInspection.notFound("x", type: nil),
            "\(DockerTemplateError(source: "{{x}}", reason: "unsupported action {{x}}"))",
        ]
        for message in messages {
            for phrase in Self.dockerDesktopTriggers { #expect(!message.lowercased().contains(phrase)) }
        }
    }
}
