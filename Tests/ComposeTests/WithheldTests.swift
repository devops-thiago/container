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

/// What does not run is not checked: a service whose profiles are off, and a network or a
/// volume nothing that runs uses.
struct WithheldTests {
    private static let shop = """
        services:
          web:
            image: web:1
          debug:
            image: debug:1
            profiles: [debug]
            privileged: true
            logging:
              driver: json-file
            env_file: missing.env
            networks: [wide]
            volumes:
              - nfs:/data
              - scratch:/scratch
        networks:
          wide:
            driver: overlay
            attachable: true
        volumes:
          nfs:
            driver: nfs
        """

    private static let refused = [
        "compose.yaml:7:5: services.debug.privileged: not supported on this engine: a container already has its own kernel; add the capabilities it needs with cap_add",
        "compose.yaml:10:15: services.debug.env_file: \(missing) does not exist",
        "compose.yaml:12:5: services.debug.volumes: the volume 'scratch' is not defined under the top-level volumes",
        "compose.yaml:17:5: networks.wide.driver: not supported on this engine: networks are of one kind, which compose calls bridge",
        "compose.yaml:21:5: volumes.nfs.driver: not supported on this engine: volumes are local disk images",
    ]
    private static let missing = "<project>/missing.env"

    private func failure(_ project: TemporaryProject, services: [String] = [], profiles: [String] = []) -> [String] {
        do {
            _ = try ProjectPlan.make(try project.load(profiles: profiles), selection: .init(services: services))
            return []
        } catch let error as ComposeError {
            return error.diagnostics.map { $0.description.replacingOccurrences(of: project.path, with: "<project>") }
        } catch {
            return ["\(error)"]
        }
    }

    @Test
    func aServiceWhoseProfileIsOffDoesNotStopTheProject() throws {
        let project = try TemporaryProject(["compose.yaml": Self.shop], named: "shop")
        let definition = try project.load()
        #expect(definition.warnings.isEmpty, "nor is anything said about it")

        let plan = try ProjectPlan.make(definition)
        #expect(plan.services.map(\.service) == ["web"])
        #expect(plan.networks.map(\.key) == ["default"])
        #expect(plan.volumes.isEmpty)
        #expect(plan.warnings.isEmpty)
    }

    @Test
    func whatWasFoundIsKeptByPart() throws {
        let project = try TemporaryProject(["compose.yaml": Self.shop], named: "shop")
        let withheld = try project.load().withheld
        #expect(Set(withheld.keys) == [.service("debug"), .network("wide"), .volume("nfs")])
        #expect(
            withheld[.service("debug")]?.map(\.path) == [
                "services.debug.privileged", "services.debug.logging", "services.debug.env_file", "services.debug.volumes",
            ], "errors and warnings, in the order the file has them")
        #expect(withheld[.service("debug")]?.map(\.severity) == [.error, .warning, .error, .error])
        #expect(withheld[.network("wide")]?.map(\.path) == ["networks.wide.driver", "networks.wide.attachable"])
        #expect(withheld[.volume("nfs")]?.map(\.path) == ["volumes.nfs.driver"])
    }

    @Test
    func aPartThatCouldNotBeReadIsNotWrittenBack() throws {
        let project = try TemporaryProject(["compose.yaml": Self.shop], named: "shop")
        let definition = try project.load()
        #expect(definition.unread.map(\.part.description) == ["services.debug", "networks.wide", "volumes.nfs"])
        #expect(definition.unread.first?.errors.map(\.path) == ["services.debug.privileged", "services.debug.env_file", "services.debug.volumes"])
        #expect(
            definition.unread.map(\.part.leftOut) == [
                "services.debug is left out: its profile is off, and it cannot run as written",
                "networks.wide is left out: no service that runs uses it, and it cannot be made as written",
                "volumes.nfs is left out: no service that runs uses it, and it cannot be made as written",
            ])

        let rendered = try definition.yaml()
        #expect(rendered == "name: shop\nservices:\n  web:\n    image: web:1\n", "written with it, it would read back as a service with nothing wrong")

        // A part that is only off, with nothing wrong, is the project's as much as any.
        let fine = """
            services:
              web:
                image: web:1
              debug:
                image: debug:1
                profiles: [debug]
                logging:
                  driver: json-file
            """
        let whole = try TemporaryProject(["compose.yaml": fine], named: "shop").load()
        #expect(whole.unread.isEmpty)
        #expect(try whole.yaml().contains("debug:\n    image: debug:1\n    profiles:\n    - debug\n"))
    }

    @Test
    func turningTheProfileOnChecksIt() throws {
        let project = try TemporaryProject(["compose.yaml": Self.shop], named: "shop")
        #expect(failure(project, profiles: ["debug"]) == Self.refused)
        #expect(failure(project, profiles: ["*"]) == Self.refused)
        #expect(try project.load(environment: ["COMPOSE_PROFILES": "other"]).withheld.count == 3)
        #expect(loadFailure { try project.load(environment: ["COMPOSE_PROFILES": "debug"]) }.count == Self.refused.count)
    }

    @Test
    func namingTheServiceChecksItAndWhatItBrings() throws {
        let project = try TemporaryProject(["compose.yaml": Self.shop], named: "shop")
        #expect(failure(project, services: ["debug"]) == Self.refused, "named, it runs whatever its profiles, so it is checked as if they were on")
        #expect(failure(project, services: ["web"]).isEmpty)
    }

    @Test
    func aWarningAboutANamedServiceIsSaidWhenItIsPlanned() throws {
        let quiet = """
            services:
              web:
                image: web:1
              debug:
                image: debug:1
                profiles: [debug]
                logging:
                  driver: json-file
                networks: [back]
            networks:
              back:
                attachable: true
            """
        let project = try TemporaryProject(["compose.yaml": quiet], named: "shop")
        let definition = try project.load()
        #expect(try ProjectPlan.make(definition).warnings.isEmpty)

        let named = try ProjectPlan.make(definition, selection: .init(services: ["debug"]))
        #expect(named.services.map(\.service) == ["debug"])
        #expect(
            named.warnings.map(\.description) == [
                "compose.yaml:7:5: services.debug.logging: ignored: the engine keeps one log per container, which logs reads",
                "compose.yaml:12:5: networks.back.attachable: ignored: any container can attach to a network",
            ])
        #expect(try ProjectPlan.make(try project.load(profiles: ["debug"])).warnings == named.warnings, "the same as with the profile on")
    }

    @Test
    func aNetworkOrVolumeNothingUsesIsNotChecked() throws {
        let unused = """
            services:
              web:
                image: web:1
                networks: [front]
                volumes:
                  - data:/data
            networks:
              front:
              wide:
                driver: overlay
            volumes:
              data:
              nfs:
                driver: nfs
            """
        let project = try TemporaryProject(["compose.yaml": unused], named: "shop")
        let definition = try project.load()
        #expect(Set(definition.withheld.keys) == [.network("wide"), .volume("nfs")])
        let plan = try ProjectPlan.make(definition)
        #expect(plan.networks.map(\.key) == ["front"])
        #expect(plan.volumes.map(\.key) == ["data"])

        // The default network is one every service without networks of its own uses.
        let byDefault = """
            services:
              web:
                image: web:1
            networks:
              default:
                driver: overlay
            """
        #expect(
            failure(try TemporaryProject(["compose.yaml": byDefault], named: "shop")) == [
                "compose.yaml:6:5: networks.default.driver: not supported on this engine: networks are of one kind, which compose calls bridge"
            ])
    }

    @Test
    func whatIsDefinedForServicesToAskForStopsNothingByItself() throws {
        let definitions = """
            secrets:
              token:
                file: ./token
            configs:
              app:
                file: ./app.conf
            models:
              llm:
                model: ai/model
            services:
              web:
                image: web:1
              vault:
                image: vault:1
                profiles: [secure]
                secrets: [token]
                configs: [app]
            """
        let project = try TemporaryProject(["compose.yaml": definitions], named: "shop")
        #expect(try ProjectPlan.make(try project.load()).services.map(\.service) == ["web"])
        #expect(
            failure(project, profiles: ["secure"]) == [
                "compose.yaml:16:5: services.vault.secrets: not supported on this engine: mount a folder that holds the file, or pass the value in environment",
                "compose.yaml:17:5: services.vault.configs: not supported on this engine: mount a folder that holds the file, or pass the value in environment",
            ], "the service that asks is where it is refused")
    }

    @Test
    func whatIsWrongWithTheProjectStillStopsIt() throws {
        // A key of the file, not of a part; a substitution, which is done before anything
        // is read; and a profiles key that cannot be read, which leaves the service on.
        let wrong = """
            include:
              - other.yaml
            volumess: {}
            services:
              web:
                image: web:1
              debug:
                image: debug:${TAG:?set TAG}
                profiles: [debug]
              broken:
                image: broken:1
                profiles: {debug: true}
                privileged: true
            """
        let project = try TemporaryProject(["compose.yaml": wrong], named: "shop")
        #expect(
            failure(project) == [
                "compose.yaml:1:1: include: not supported on this engine: name each file with -f instead",
                "compose.yaml:3:1: volumess: not a compose key",
                "compose.yaml:8:12: required variable TAG is missing a value: set TAG",
                "compose.yaml:12:15: services.broken.profiles: expected a list, found a mapping",
                "compose.yaml:13:5: services.broken.privileged: not supported on this engine: a container already has its own kernel; add the capabilities it needs with cap_add",
            ])
    }

    @Test
    func aProfileGivenInALaterFileCounts() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": "services:\n  web:\n    image: web:1\n  debug:\n    image: debug:1\n    privileged: true\n",
                "compose.override.yaml": "services:\n  debug:\n    profiles: [debug]\n",
            ], named: "shop")
        #expect(
            failure(project, files: ["compose.yaml"]) == [
                "compose.yaml:6:5: services.debug.privileged: not supported on this engine: a container already has its own kernel; add the capabilities it needs with cap_add"
            ], "alone, the first file has the service on")
        #expect(failure(project, files: ["compose.yaml", "compose.override.yaml"]).isEmpty)
    }

    private func failure(_ project: TemporaryProject, files: [String]) -> [String] {
        loadFailure { try project.load(files: files) }
    }

    @Test
    func anOptionalDependencyOnAServiceThatIsOffLeavesItUnchecked() throws {
        let optional = """
            services:
              web:
                image: web:1
                depends_on:
                  metrics:
                    required: false
              metrics:
                image: metrics:1
                profiles: [observability]
                pid: host
            """
        let project = try TemporaryProject(["compose.yaml": optional], named: "shop")
        let plan = try ProjectPlan.make(try project.load())
        #expect(plan.services.map(\.service) == ["web"])
        #expect(plan.warnings.map(\.message) == ["'metrics' is not started: its profile is not active and the dependency is not required"])
    }
}
