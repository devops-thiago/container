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
}
