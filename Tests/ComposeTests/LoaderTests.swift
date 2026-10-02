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

import Foundation
import Testing

@testable import ContainerCompose

struct DiscoveryTests {
    @Test
    func theFirstNameInTheOrderWins() throws {
        let service = "services:\n  web:\n    image: "
        let project = try TemporaryProject([
            "docker-compose.yml": service + "from-docker-compose-yml",
            "docker-compose.yaml": service + "from-docker-compose-yaml",
            "compose.yml": service + "from-compose-yml",
            "compose.yaml": service + "from-compose-yaml",
        ])
        var expected = ["from-compose-yaml", "from-compose-yml", "from-docker-compose-yaml", "from-docker-compose-yml"]
        for name in ComposeLoader.defaultFileNames {
            let definition = try project.load()
            #expect(definition.file.service("web")?.image == expected.removeFirst())
            #expect(definition.configFiles == ["\(project.path)/\(name)"])
            try FileManager.default.removeItem(at: project.directory.appendingPathComponent(name))
        }
        #expect(loadFailure { try project.load() }.first?.contains("no compose file found") == true)
    }

    @Test
    func anOverrideBesideTheFileIsMergedOverIt() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:1\n",
            "compose.override.yml": "services:\n  web:\n    image: web:dev\n",
        ])
        let definition = try project.load()
        #expect(definition.file.service("web")?.image == "web:dev")
        #expect(definition.configFiles == ["\(project.path)/compose.yaml", "\(project.path)/compose.override.yml"])
    }

    @Test
    func namedFilesAreNotJoinedByAnOverride() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:1\n",
            "compose.override.yaml": "services:\n  web:\n    image: web:dev\n",
        ])
        #expect(try project.load(files: ["compose.yaml"]).file.service("web")?.image == "web:1")
    }

    @Test
    func theSearchGoesUpOnlyWhenAsked() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n"])
        try project.makeDirectory("src/deep")
        let deep = "\(project.path)/src/deep"
        let found = try project.load(workingDirectory: deep, searchesParents: true)
        #expect(found.directory == project.path)
        #expect(found.name == "project")
        #expect(loadFailure { try project.load(workingDirectory: deep, searchesParents: false) }.count == 1)
    }

    @Test
    func namedFilesAreRelativeToWhereComposeRuns() throws {
        let project = try TemporaryProject([
            "deploy/base.yaml": "services:\n  web:\n    image: web:1\n    volumes:\n      - ./data:/data\n",
            "deploy/prod.yaml": "services:\n  web:\n    environment:\n      MODE: production\n",
        ])
        let definition = try project.load(files: ["deploy/base.yaml", "deploy/prod.yaml"])
        #expect(definition.directory == "\(project.path)/deploy", "paths in the files are relative to the first file")
        #expect(definition.name == "deploy")
        let web = try #require(definition.file.service("web"))
        #expect(web.environment == ["MODE": "production"])
        #expect(web.mounts == [ComposeMount(kind: .bind(source: "\(project.path)/deploy/data"), target: "/data")])

        let moved = try project.load(files: ["deploy/base.yaml"], projectDirectory: ".")
        #expect(moved.directory == project.path)
        #expect(moved.file.service("web")?.mounts.first?.kind == .bind(source: "\(project.path)/data"))
    }

    @Test
    func theEnvironmentCanNameTheFiles() throws {
        let project = try TemporaryProject([
            "one.yaml": "services:\n  web:\n    image: web:1\n",
            "two.yaml": "services:\n  web:\n    image: web:2\n",
        ])
        #expect(try project.load(environment: ["COMPOSE_FILE": "one.yaml:two.yaml"]).file.service("web")?.image == "web:2")
        #expect(
            try project.load(environment: ["COMPOSE_FILE": "two.yaml,one.yaml", "COMPOSE_PATH_SEPARATOR": ","]).file.service("web")?.image
                == "web:1")
        #expect(loadFailure { try project.load(files: ["missing.yaml"]) }.first?.contains("missing.yaml does not exist") == true)
    }
}

struct ProjectNameTests {
    private let file = ["compose.yaml": "name: from-file\nservices:\n  web:\n    image: web:1\n"]

    @Test
    func theOptionWinsThenTheEnvironmentThenTheFileThenTheDirectory() throws {
        let named = try TemporaryProject(file, named: "My App.v2")
        #expect(try named.load(name: "from-option", environment: ["COMPOSE_PROJECT_NAME": "from-environment"]).name == "from-option")
        #expect(try named.load(environment: ["COMPOSE_PROJECT_NAME": "from-environment"]).name == "from-environment")
        #expect(try named.load().name == "from-file")

        let unnamed = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n"], named: "My App.v2")
        #expect(try unnamed.load().name == "myappv2")
    }

    @Test
    func aNameInTheEnvFileCounts() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:1\n", ".env": "COMPOSE_PROJECT_NAME=from-dotenv\n",
        ])
        #expect(try project.load().name == "from-dotenv")
    }

    @Test
    func theNameIsAVariableTheFilesCanUse() throws {
        let project = try TemporaryProject(
            ["compose.yaml": "services:\n  web:\n    image: web:1\n    hostname: ${COMPOSE_PROJECT_NAME}-web\n"], named: "shop")
        #expect(try project.load().file.service("web")?.hostname == "shop-web")
    }

    @Test(arguments: ["Capital", "-leading", "has space", "dot.ted", ""])
    func aNameThatIsNotOneIsRefused(_ name: String) throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n"])
        if name.isEmpty {
            #expect(try project.load(name: name).name == "project", "no name given is no name given")
        } else {
            #expect(loadFailure { try project.load(name: name) }.first?.contains("is not a project name") == true)
        }
    }

    @Test
    func aDirectoryWithNoUsableNameAsksForOne() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n"], named: "___")
        #expect(loadFailure { try project.load() }.first?.contains("give one with -p") == true)
    }

    @Test(arguments: [("shop", true), ("shop-2_x", true), ("2shop", true), ("Shop", false), ("_shop", false), ("sh op", false), ("", false)])
    func validity(_ name: String, _ valid: Bool) {
        #expect(ComposeLoader.nameValid(name) == valid)
    }
}

struct VariableTests {
    @Test
    func theEnvFileFeedsTheFilesAndTheEnvironmentWins() throws {
        let project = try TemporaryProject([
            "compose.yaml": """
            services:
              web:
                image: web:${TAG:-latest}
                environment:
                  REGION: ${REGION}
                  LEVEL: ${LEVEL:-info}
            """,
            ".env": "TAG=1.4\nREGION=eu\n",
        ])
        let fromFile = try #require(try project.load().file.service("web"))
        #expect(fromFile.image == "web:1.4")
        #expect(fromFile.environment == ["REGION": "eu", "LEVEL": "info"])

        let overridden = try #require(try project.load(environment: ["TAG": "2.0", "LEVEL": "debug"]).file.service("web"))
        #expect(overridden.image == "web:2.0")
        #expect(overridden.environment == ["REGION": "eu", "LEVEL": "debug"])
    }

    @Test
    func aNamedEnvFileTakesThePlaceOfTheDefault() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:${TAG:-latest}\n",
            ".env": "TAG=default\n",
            "prod.env": "TAG=prod\n",
        ])
        #expect(try project.load(envFiles: ["prod.env"]).file.service("web")?.image == "web:prod")
        #expect(loadFailure { try project.load(envFiles: ["absent.env"]) }.first?.contains("absent.env does not exist") == true)
    }

    @Test
    func aVariableThatIsNotSetIsEmptyAndSaidSo() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n    hostname: a${MISSING}b${MISSING}\n"])
        let definition = try project.load()
        #expect(definition.file.service("web")?.hostname == "ab")
        #expect(definition.warnings.map(\.description) == ["the variable MISSING is not set; it reads as an empty string"])
    }

    @Test
    func aBrokenSubstitutionNamesItsLine() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n    hostname: ${HOST:?set HOST first}\n"])
        #expect(loadFailure { try project.load() } == ["compose.yaml:4:15: required variable HOST is missing a value: set HOST first"])
    }

    @Test
    func keysAreNotSubstituted() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n    labels:\n      $KEY: ${VALUE}\n"])
        #expect(try project.load(environment: ["KEY": "k", "VALUE": "v"]).file.service("web")?.labels == ["$KEY": "v"])
    }

    @Test
    func profilesComeFromTheOptionAndTheEnvironment() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n"])
        #expect(try project.load(profiles: ["debug"], environment: ["COMPOSE_PROFILES": "tools, debug,metrics"]).profiles == ["debug", "tools", "metrics"])
    }
}

struct MergeTests {
    @Test
    func aLaterFileAddsToAnEarlierOne() throws {
        let definition = try Fixture.load("override")
        let directory = try Fixture.directory("override")
        #expect(definition.name == "shop")
        #expect(definition.file.services.map(\.name) == ["cache", "db", "web"])

        let web = try #require(definition.file.service("web"))
        #expect(web.command == ["serve", "--port", "8000", "--reload"], "a command is one value, replaced whole")
        #expect(web.environment == ["MODE": "development", "LOG_LEVEL": "info", "DEBUG": "1"], "an environment merges by name, whichever form it is written in")
        #expect(
            web.ports == [
                ComposePort(published: "8000", target: "8000"),
                ComposePort(published: "9229", target: "9229"),
            ], "ports add up")
        #expect(
            web.mounts == [
                ComposeMount(kind: .volume(key: "assets"), target: "/srv/assets"),
                ComposeMount(kind: .bind(source: "\(directory)/src"), target: "/srv/public"),
            ], "a mount replaces the one with the same target")
        #expect(
            web.dependsOn == [
                ComposeDependency(service: "cache"),
                ComposeDependency(service: "db", condition: .healthy),
            ], "a dependency replaces the one on the same service")
        #expect(web.labels == ["team": "storefront", "tier": "dev"])
        #expect(
            web.healthcheck
                == ComposeHealthcheck(test: ["curl", "-f", "http://localhost:8000/health"], interval: 5),
            "a healthcheck merges field by field")

        let db = try #require(definition.file.service("db"))
        #expect(db.image == "postgres:16")
        #expect(db.healthcheck?.test == ["/bin/sh", "-c", "pg_isready -U postgres"])
    }

    @Test
    func theBaseAloneIsWhatItSays() throws {
        let definition = try Fixture.load("override", files: ["compose.yaml"])
        let web = try #require(definition.file.service("web"))
        #expect(web.command == ["serve", "--port", "8000"])
        #expect(web.environment == ["MODE": "production", "LOG_LEVEL": "info"])
        #expect(web.mounts.last == ComposeMount(kind: .bind(source: "\(try Fixture.directory("override"))/public"), target: "/srv/public", readOnly: true))
        #expect(web.dependsOn == [ComposeDependency(service: "db")])
        #expect(definition.file.services.map(\.name) == ["db", "web"])
    }

    @Test
    func topLevelNetworksAndVolumesMergeToo() throws {
        let project = try TemporaryProject([
            "a.yaml": """
            services:
              web:
                image: web:1
            networks:
              front:
                labels:
                  owner: a
            volumes:
              data:
                labels: ["owner=a"]
            """,
            "b.yaml": """
            networks:
              front:
                internal: true
                labels:
                  tier: edge
              back: {}
            volumes:
              data:
                external: true
            """,
        ])
        let file = try project.load(files: ["a.yaml", "b.yaml"]).file
        #expect(file.networks.map(\.key) == ["back", "front"])
        let front = try #require(file.networks.first { $0.key == "front" })
        #expect(front.isInternal)
        #expect(front.labels == ["owner": "a", "tier": "edge"])
        let data = try #require(file.volumes.first)
        #expect(data.external)
        #expect(data.labels == ["owner": "a"])
    }
}
