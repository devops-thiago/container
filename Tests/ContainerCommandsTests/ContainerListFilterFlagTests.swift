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
import Foundation
import Testing

@testable import ContainerCommands

/// `container list --filter`, from the command line to the filters the engine is sent.
struct ContainerListFilterFlagTests {
    private typealias Command = Application.ContainerList

    private func filters(_ arguments: [String]) throws -> ContainerListFilters {
        let command = try Command.parse(arguments)
        return try Command.filters(for: command.filter, all: command.all)
    }

    /// The message the user would see, or nothing when the arguments are accepted.
    private func refusal(_ arguments: [String]) -> String {
        do {
            _ = try filters(arguments)
            return ""
        } catch {
            return Command.message(for: error)
        }
    }

    /// The engine searches a container's value for the pattern; this is that search.
    private func matches(_ pattern: String, _ value: String) throws -> Bool {
        value.contains(try Regex(pattern))
    }

    @Test("a label with a value matches exactly that value, whatever it contains")
    func labelValue() throws {
        let app = try #require(try filters(["--filter", "label=app=web"]).labels["app"])
        #expect(try matches(app, "web"))
        #expect(try !matches(app, "webserver"))
        #expect(try !matches(app, "myweb"))
        #expect(try !matches(app, ""))
        #expect(try !matches(app, "web\nx"))

        let version = try #require(try filters(["--filter", "label=version=1.2"]).labels["version"])
        #expect(try matches(version, "1.2"))
        #expect(try !matches(version, "1x2"))

        let url = try #require(try filters(["--filter", "label=url=http://a/b?c=(d)"]).labels["url"])
        #expect(try matches(url, "http://a/b?c=(d)"))
        #expect(try !matches(url, "http://a/b?c=d"))
    }

    @Test("a label alone requires its key, including when its value is empty")
    func labelPresence() throws {
        let value = try filters(["--filter", "label=app"])
        #expect(value.labels.isEmpty)
        #expect(value.labelConditions == [.init(key: "app")])
        let empty = try filters(["--filter", "label=app="])
        #expect(empty.labelConditions == [.init(key: "app")])
        #expect(try matches(try #require(empty.labels["app"]), ""))
        #expect(try !matches(try #require(empty.labels["app"]), "web"))
    }

    @Test("every condition is sent, and a label's value may itself contain '='")
    func conditionsCombine() throws {
        let filters = try filters([
            "--filter", "label=app=web",
            "--filter", "label=env=a=b",
            "--filter", "name=^web",
            "--filter", "status=stopped",
        ])
        #expect(filters.labels.keys.sorted() == ["app", "env"])
        #expect(try matches(try #require(filters.labels["env"]), "a=b"))
        #expect(filters.name == "^web")
        #expect(filters.status == .stopped)
        #expect(filters.ids.isEmpty)
    }

    @Test("a name goes to the engine as the regular expression it is")
    func name() throws {
        #expect(try filters(["--filter", "name=^(web|db)-[0-9]+$"]).name == "^(web|db)-[0-9]+$")
        #expect(try filters([]).name == nil)
    }

    @Test("a status condition replaces the default of leaving stopped containers out, so it needs no --all")
    func status() throws {
        #expect(try filters([]).status == nil)
        #expect(try filters(["--all"]).status == nil)
        #expect(try filters(["--filter", "status=stopped"]).status == .stopped)
        #expect(try filters(["--all", "--filter", "status=running"]).status == .running)
        #expect(try filters(["--filter", "status=stopping"]).status == .stopping)
    }

    @Test("without --all or a status condition only stopped containers are left out, so restarting ones show")
    func hidesStopped() throws {
        func hides(_ arguments: [String]) throws -> Bool {
            let command = try Command.parse(arguments)
            return Command.hidesStopped(for: command.filter, all: command.all)
        }
        #expect(try hides([]))
        #expect(try hides(["--filter", "name=web"]))
        #expect(try !hides(["--all"]))
        #expect(try !hides(["--filter", "status=stopped"]))
        #expect(try !hides(["--filter", "status=restarting"]))
        #expect(try filters(["--filter", "status=restarting"]).status == .restarting)
    }

    @Test("an unknown key is refused naming the known ones")
    func unknownKey() {
        let message = refusal(["--filter", "created=today"])
        #expect(message.contains("created=today"))
        #expect(message.contains("label, name and status"))
    }

    @Test("a malformed condition says what it needed")
    func malformed() {
        #expect(refusal(["--filter", "running"]).contains("<key>=<value>"))
        #expect(refusal(["--filter", "label="]).contains("needs a key"))
        #expect(refusal(["--filter", "name="]).contains("regular expression"))
        let status = refusal(["--filter", "status=paused"])
        #expect(status.contains("paused"))
        #expect(status.contains("running"))
        #expect(status.contains("stopped"))
    }

    @Test("repeated labels combine with AND; name and status remain single conditions")
    func repeats() throws {
        let repeated = try filters(["--filter", "label=app=web", "--filter", "label=app=db"])
        #expect(repeated.labels["app"] == "^web$")
        #expect(repeated.labelConditions == [.init(key: "app"), .init(key: "app"), .init(key: "app", pattern: "^db$")])
        let present = try filters(["--filter", "label=app=web", "--filter", "label=app"])
        #expect(present.labels["app"] == "^web$")
        #expect(present.labelConditions == [.init(key: "app"), .init(key: "app")])
        #expect(refusal(["--filter", "name=web", "--filter", "name=db"]).contains("(web|db)"))
        #expect(refusal(["--filter", "status=running", "--filter", "status=stopped"]).contains("status"))
        #expect(try filters(["--filter", "label=app=web", "--filter", "label=tier=front"]).labels.count == 2)
    }
}
