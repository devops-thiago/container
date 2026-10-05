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
import ContainerResource
import Testing

@testable import ContainerCommands

/// The spellings a person brings from another container CLI reach the commands this one
/// already has.
struct DockerSpellingTests {
    private func parse<Command: ParsableCommand>(_ arguments: [String], as type: Command.Type = Command.self) throws -> Command {
        try #require(try Application.parseAsRoot(arguments) as? Command, "\(arguments) did not parse as \(Command.self)")
    }

    @Test("ps is ls, flags included")
    func ps() throws {
        let list: Application.ContainerList = try parse(["ps", "-a", "-q", "--filter", "name=web"])
        #expect(list.all)
        #expect(list.quiet)
        #expect(list.filter.count == 1)
        _ = try parse(["ls"], as: Application.ContainerList.self)
        _ = try parse(["list", "--format", "json"], as: Application.ContainerList.self)
    }

    @Test("the container noun reaches the same verbs")
    func noun() throws {
        let list: Application.ContainerList = try parse(["container", "ls", "-a"])
        #expect(list.all)
        _ = try parse(["container", "prune"], as: Application.ContainerPrune.self)
        _ = try parse(["container", "rm", "-f", "web"], as: Application.ContainerDelete.self)
        _ = try parse(["container", "inspect", "web"], as: Application.ContainerInspect.self)
        #expect(Application.ContainerNoun.configuration.subcommands.count == Application.containerVerbs.count)
        #expect(!Application.ContainerNoun.configuration.shouldDisplay)
    }

    @Test("logs takes --tail for -n")
    func logsTail() throws {
        let tail: Application.ContainerLogs = try parse(["logs", "--tail", "5", "web"])
        #expect(tail.numLines == 5)
        let short: Application.ContainerLogs = try parse(["logs", "-n", "7", "web"])
        #expect(short.numLines == 7)
    }

    @Test("restart takes the stop flags and at least one container")
    func restart() throws {
        let restart: Application.ContainerRestart = try parse(["restart", "-t", "2", "--signal", "SIGINT", "a", "b"])
        #expect(restart.time == 2)
        #expect(restart.signal == "SIGINT")
        #expect(restart.containerIds == ["a", "b"])
        #expect(throws: (any Error).self) { try Application.parseAsRoot(["restart"]) }
        _ = try parse(["container", "restart", "a"], as: Application.ContainerRestart.self)
    }

    @Test("the image verbs are spelled at the root too, with their own flags")
    func imageVerbs() throws {
        let images: Application.Images = try parse(["images", "-q"])
        #expect(images.command.quiet)
        let pull: Application.Pull = try parse(["pull", "--platform", "linux/arm64", "alpine"])
        #expect(pull.command.reference == "alpine")
        let tag: Application.Tag = try parse(["tag", "alpine", "mine/alpine:v1"])
        #expect(tag.command.source == "alpine")
        #expect(tag.command.target == "mine/alpine:v1")
        let remove: Application.RemoveImage = try parse(["rmi", "alpine", "nginx"])
        #expect(remove.command.options.images == ["alpine", "nginx"])
        let save: Application.Save = try parse(["save", "-o", "/tmp/a.tar", "alpine"])
        #expect(save.command.references == ["alpine"])
        let load: Application.Load = try parse(["load", "-i", "/tmp/a.tar"])
        #expect(load.command.input == "/tmp/a.tar")
        _ = try parse(["push", "ghcr.io/me/app:1"], as: Application.Push.self)
        for spelling in Application.imageRootSpellings {
            #expect(!spelling.configuration.shouldDisplay, "\(spelling) stays out of the root help")
        }
    }

    @Test("image rm is image delete, and image ls takes a repository")
    func imageSubcommands() throws {
        _ = try parse(["image", "rm", "alpine"], as: Application.ImageDelete.self)
        let list: Application.ImageList = try parse(["image", "ls", "alpine"])
        #expect(list.reference == "alpine")
        let all: Application.ImageList = try parse(["image", "ls"])
        #expect(all.reference == nil)
        let images: Application.Images = try parse(["images", "alpine:3.22"])
        #expect(images.command.reference == "alpine:3.22")
    }

    @Test("a repository filter names its tags and nothing that merely starts like it")
    func imageFilter() {
        let names = Application.ImageList.names
        #expect(names("alpine", "docker.io/library/alpine:latest", "alpine:latest"))
        #expect(names("alpine:latest", "docker.io/library/alpine:latest", "alpine:latest"))
        #expect(names("docker.io/library/alpine", "docker.io/library/alpine:3.22", "alpine:3.22"))
        #expect(names("ghcr.io/me/app", "ghcr.io/me/app@sha256:abc", "ghcr.io/me/app@sha256:abc"))
        #expect(!names("alp", "docker.io/library/alpine:latest", "alpine:latest"))
        #expect(!names("alpine:3", "docker.io/library/alpine:3.22", "alpine:3.22"))
        #expect(!names("nginx", "docker.io/library/alpine:latest", "alpine:latest"))
    }

    @Test("every prune takes -f and --force, which change nothing")
    func pruneForce() throws {
        let containers: Application.ContainerPrune = try parse(["prune", "-f"])
        #expect(containers.confirmation.force)
        let images: Application.ImagePrune = try parse(["image", "prune", "-f", "-a"])
        #expect(images.all && images.confirmation.force)
        let volumes: Application.VolumeCommand.VolumePrune = try parse(["volume", "prune", "--force"])
        #expect(volumes.confirmation.force && !volumes.all)
        let everyVolume: Application.VolumeCommand.VolumePrune = try parse(["volume", "prune", "-a", "-f"])
        #expect(everyVolume.all)
        #expect(try parse(["volume", "prune", "--all"], as: Application.VolumeCommand.VolumePrune.self).all)
        if #available(macOS 26, *) {
            _ = try parse(["network", "prune", "-f"], as: Application.NetworkCommand.NetworkPrune.self)
        }
        let plain: Application.ContainerPrune = try parse(["prune"])
        #expect(!plain.confirmation.force)
        #expect(!Application.ContainerPrune.helpMessage().contains("--force"), "the flag does nothing, so help does not list it")
    }

    /// A named volume has no container whenever its containers are removed and made again,
    /// as `compose down` leaves it. `docker volume prune` keeps it unless `--all` is given,
    /// and so does this one: with `-f` accepted, the Docker spelling runs here as typed.
    @Test("volume prune removes anonymous volumes, and named ones only with --all")
    func volumePruneKeepsNamedVolumes() {
        typealias Prune = Application.VolumeCommand.VolumePrune
        func volume(_ name: String, anonymous: Bool = false) -> VolumeConfiguration {
            VolumeConfiguration(
                name: name, source: "/volumes/\(name)",
                labels: anonymous ? [VolumeConfiguration.anonymousLabel: ""] : [:])
        }
        let volumes = [
            volume("shop_data"), volume("held"), volume("5a2f", anonymous: true), volume("9c1e", anonymous: true),
        ]
        let inUse: Set<String> = ["held", "9c1e"]

        let plain = Prune.selection(from: volumes, inUse: inUse, all: false)
        #expect(plain.prune.map(\.name) == ["5a2f"], "the anonymous volume nothing refers to, and nothing named")
        #expect(plain.kept == 1, "shop_data: named, unreferenced, and said to have been kept")

        let all = Prune.selection(from: volumes, inUse: inUse, all: true)
        #expect(all.prune.map(\.name) == ["shop_data", "5a2f"])
        #expect(all.kept == 0)

        #expect(Prune.selection(from: volumes, inUse: Set(volumes.map(\.name)), all: true).prune.isEmpty, "a volume a container refers to is never pruned")
    }

    @Test("system prune is the prune commands in order, volumes only when asked")
    func systemPrune() throws {
        let prune: Application.SystemPrune = try parse(["system", "prune", "-f", "-a", "--volumes"])
        #expect(prune.all && prune.volumes && prune.confirmation.force)
        typealias Prune = Application.SystemPrune
        #expect(Prune.steps(all: false, volumes: false, networks: true) == [["prune"], ["network", "prune"], ["image", "prune"]])
        #expect(Prune.steps(all: true, volumes: true, networks: true) == [["prune"], ["network", "prune"], ["image", "prune", "--all"], ["volume", "prune"]])
        #expect(Prune.steps(all: false, volumes: false, networks: false) == [["prune"], ["image", "prune"]])
        #expect(
            Prune.steps(all: true, volumes: true, debug: true, networks: false) == [
                ["prune", "--debug"], ["image", "prune", "--debug", "--all"], ["volume", "prune", "--debug"],
            ])
        // Every step is a command line this CLI parses, so none can go to a plugin lookup.
        for step in Prune.steps(all: true, volumes: true, debug: true) {
            let command = try Application.parseAsRoot(step)
            #expect(!(command is DefaultCommand), "\(step)")
        }
    }

    @Test("version and info at the root are system version and system status")
    func versionAndInfo() throws {
        let version: Application.Version = try parse(["version", "--format", "json"])
        #expect(version.command.format == .json)
        _ = try parse(["version"], as: Application.Version.self)
        let info: Application.Info = try parse(["info", "--format", "json"])
        #expect(info.command.format == .json)
        _ = try parse(["system", "version"], as: Application.SystemVersion.self)
        _ = try parse(["system", "status"], as: Application.SystemStatus.self)
        for spelling in Application.systemRootSpellings {
            #expect(!spelling.configuration.shouldDisplay)
        }
    }
}
