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

struct PlanTests {
    private func plan(
        _ yaml: String, named name: String = "shop", services: [String] = [], dependencies: Bool = true, profiles: [String] = []
    ) throws -> ProjectPlan {
        let project = try TemporaryProject(["compose.yaml": yaml], named: name)
        return try ProjectPlan.make(
            try project.load(profiles: profiles), selection: .init(services: services, includesDependencies: dependencies))
    }

    private func failure(_ yaml: String, named name: String = "shop", services: [String] = [], profiles: [String] = []) -> [String] {
        do {
            _ = try plan(yaml, named: name, services: services, profiles: profiles)
            return []
        } catch let error as ComposeError {
            return error.diagnostics.map(\.description)
        } catch {
            return ["\(error)"]
        }
    }

    private static let chain = """
        services:
          web:
            image: web:1
            depends_on: [api, cache]
          api:
            image: api:1
            depends_on:
              db:
                condition: service_healthy
          db:
            image: postgres:16
            healthcheck:
              test: pg_isready
          cache:
            image: redis:8
          tools:
            image: tools:1
            profiles: [debug]
            depends_on: [db]
        """

    @Test
    func servicesStartAfterWhatTheyDependOn() throws {
        let plan = try plan(Self.chain)
        #expect(plan.services.map(\.service) == ["cache", "db", "api", "web"])
        #expect(plan.service("api")?.dependencies == [ComposeDependency(service: "db", condition: .healthy)])
        #expect(plan.service("web")?.dependencies.map(\.service) == ["api", "cache"])
        #expect(plan.service("tools") == nil, "a service in a profile nobody asked for stays out")
    }

    @Test
    func aNamedServiceBringsWhatItNeeds() throws {
        #expect(try plan(Self.chain, services: ["api"]).services.map(\.service) == ["db", "api"])
        let alone = try plan(Self.chain, services: ["api"], dependencies: false)
        #expect(alone.services.map(\.service) == ["api"])
        #expect(alone.services[0].dependencies.isEmpty)
        let pair = try plan(Self.chain, services: ["api", "db"], dependencies: false)
        #expect(pair.services.map(\.service) == ["db", "api"], "the ones named still start in order")
        #expect(failure(Self.chain, services: ["ghost"]) == ["there is no service named 'ghost'"])
    }

    @Test
    func profilesTurnServicesOn() throws {
        #expect(try plan(Self.chain, profiles: ["debug"]).services.map(\.service) == ["cache", "db", "api", "tools", "web"])
        #expect(try plan(Self.chain, profiles: ["*"]).services.count == 5)
        #expect(try plan(Self.chain, services: ["tools"]).services.map(\.service) == ["db", "tools"], "naming a service runs it whatever its profiles")
    }

    @Test
    func aDependencyInAnInactiveProfileIsAnErrorUnlessOptional() throws {
        let required = """
            services:
              web:
                image: web:1
                depends_on: [metrics]
              metrics:
                image: metrics:1
                profiles: [observability, full]
            """
        #expect(
            failure(required) == [
                "compose.yaml:2:3: services.web.depends_on.metrics: 'metrics' is in the profile observability, full, which is not active; add --profile observability"
            ])
        #expect(try plan(required, profiles: ["full"]).services.map(\.service) == ["metrics", "web"])

        let optional = required.replacingOccurrences(of: "depends_on: [metrics]", with: "depends_on:\n      metrics:\n        required: false")
        let plan = try plan(optional)
        #expect(plan.services.map(\.service) == ["web"])
        #expect(plan.services[0].dependencies.isEmpty)
        #expect(plan.warnings.map(\.message) == ["'metrics' is not started: its profile is not active and the dependency is not required"])
    }

    @Test
    func aCircleIsNamed() {
        let circle = """
            services:
              a:
                image: a
                depends_on: [b]
              b:
                image: b
                depends_on: [c]
              c:
                image: c
                depends_on: [a]
              d:
                image: d
                depends_on: [a]
            """
        #expect(failure(circle) == ["services depend on each other in a circle: a → b → c → a"])
    }

    @Test
    func everythingIsNamedAfterTheProject() throws {
        let plan = try plan(
            """
            services:
              web:
                image: web:1
                volumes:
                  - assets:/srv/assets
                  - theirs:/srv/theirs
                  - renamed:/srv/renamed
                networks: [default, back, edge, shared]
              db:
                image: postgres:16
                container_name: the-database
            networks:
              back:
                internal: true
                labels:
                  tier: data
              edge:
                name: edge-net
                ipam:
                  config:
                    - subnet: 10.90.0.0/24
              shared:
                external: true
              unused:
            volumes:
              assets:
              theirs:
                external: true
              renamed:
                name: asset-archive
              unused:
            """)
        #expect(plan.name == "shop")
        #expect(plan.service("web")?.containerName == "shop-web-1")
        #expect(plan.service("db")?.containerName == "the-database")
        #expect(
            plan.networks == [
                NetworkPlan(
                    key: "back", name: "shop_back", external: false, isInternal: true, subnet: nil,
                    labels: ["tier": "data", "com.docker.compose.project": "shop", "com.docker.compose.network": "back"]),
                NetworkPlan(
                    key: "default", name: "shop_default", external: false, isInternal: false, subnet: nil,
                    labels: ["com.docker.compose.project": "shop", "com.docker.compose.network": "default"]),
                NetworkPlan(
                    key: "edge", name: "edge-net", external: false, isInternal: false, subnet: "10.90.0.0/24",
                    labels: ["com.docker.compose.project": "shop", "com.docker.compose.network": "edge"]),
                NetworkPlan(key: "shared", name: "shop_shared", external: true, isInternal: false, subnet: nil, labels: [:]),
            ], "only the networks a planned service uses")
        #expect(
            plan.volumes == [
                VolumePlan(
                    key: "assets", name: "shop_assets", external: false,
                    labels: ["com.docker.compose.project": "shop", "com.docker.compose.volume": "assets"]),
                VolumePlan(
                    key: "renamed", name: "asset-archive", external: false,
                    labels: ["com.docker.compose.project": "shop", "com.docker.compose.volume": "renamed"]),
                VolumePlan(key: "theirs", name: "shop_theirs", external: true, labels: [:]),
            ])
    }

    @Test
    func aVolumeSeveralServicesMountIsSaidToBeOneAtATime() throws {
        let plan = try plan(
            """
            services:
              web:
                image: web:1
                volumes: [media:/media, cache:/cache]
              worker:
                image: web:1
                volumes:
                  - media:/media
              other:
                image: other:1
                volumes: [./shared:/shared]
            volumes:
              media:
              cache:
            """)
        #expect(
            plan.warnings.map(\.description) == [
                "volumes.media: mounted by web, worker: a volume is a disk that one running container holds at a time, so these services cannot run at the same time. Services that run together share files through a folder mounted into each"
            ])
    }

    @Test
    func namesTheEngineCannotTakeAreRefused() {
        let long = String(repeating: "x", count: 50)
        #expect(
            failure("services:\n  \(long):\n    image: a\n", named: "a-long-project-name").first?
                .contains("is longer than the 63 characters a container name can have") == true)
        #expect(
            failure("services:\n  a:\n    image: a\n    container_name: same\n  b:\n    image: b\n    container_name: same\n")
                == ["the services a and b would both be the container 'same'"])
        #expect(
            failure("services:\n  a:\n    image: a\n    networks: [n]\nnetworks:\n  n:\n    name: Upper_Case\n").first?
                .contains("'Upper_Case' is not a network name") == true)
        #expect(
            failure("services:\n  a:\n    image: a\nnetworks:\n  default:\n    labels:\n      Not_Valid: x\n").first?
                .contains("'Not_Valid' is not a label this engine takes on a network or a volume") == true)
        #expect(
            failure("services:\n  a:\n    image: a\n    labels:\n      com.docker.compose.project: mine\n").first?
                .contains("'com.docker.compose.project' is a label compose sets itself") == true)
    }

    @Test
    func valuesTheEngineWouldRefuseAreRefusedByThePlan() {
        #expect(
            failure("services:\n  a:\n    image: a\n    cap_add: [NOT_A_CAPABILITY]\n").first?.hasPrefix("compose.yaml:2:3: services.a: ") == true)
        #expect(failure("services:\n  a:\n    image: a\n    sysctls:\n      - no-equals-sign\n").count == 1)
        #expect(failure("services:\n  a:\n    image: a\n    extra_hosts:\n      - \"name:not an address\"\n").count == 1)
        #expect(failure("services:\n  a:\n    image: a\n    ulimits:\n      imaginary: 5\n").count == 1)
    }
}

struct LoweringTests {
    private func arguments(_ settings: String, extra: String = "", environment: [String: String] = [:]) throws -> (ServicePlan, [String]) {
        let indented = settings.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n\(indented)\n\(extra)"], named: "shop")
        let plan = try ProjectPlan.make(try project.load(environment: environment))
        let service = try #require(plan.service("web"))
        return (service, plan.warnings.map(\.description))
    }

    /// The options a service's settings add to the ones every service has: its name in
    /// front, its place on the default network, and compose's own seven labels at the end.
    private func added(_ settings: String, extra: String = "") throws -> [String] {
        let (service, _) = try arguments(settings, extra: extra)
        var options = Array(service.options.dropLast(14))
        #expect(Array(options.prefix(3)) == ["--detach", "--name", "shop-web-1"])
        options.removeFirst(3)
        if let network = options.firstIndex(of: "shop_default,alias=web") {
            options.removeSubrange((network - 1)...network)
        }
        return options
    }

    @Test
    func aBareServiceIsItsNameItsNetworkAndItsLabels() throws {
        let (service, warnings) = try arguments("")
        #expect(warnings.isEmpty)
        #expect(service.image == "web:1")
        #expect(service.command.isEmpty)
        let labels = service.options.enumerated().filter { $0.element == "--label" }.map { service.options[$0.offset + 1] }
        #expect(
            Array(service.options.prefix(5)) == ["--detach", "--name", "shop-web-1", "--network", "shop_default,alias=web"])
        #expect(
            labels.map { String($0.prefix { $0 != "=" }) } == [
                "com.docker.compose.project", "com.docker.compose.service", "com.docker.compose.container-number", "com.docker.compose.oneoff",
                "com.docker.compose.project.working_dir", "com.docker.compose.project.config_files", "com.docker.compose.config-hash",
            ])
        #expect(labels.last == "com.docker.compose.config-hash=\(service.configHash)")
        #expect(service.configHash.count == 64)
    }

    @Test
    func settingsBecomeTheOptionsRunTakes() throws {
        #expect(try added("hostname: front") == ["--hostname", "front"])
        #expect(
            try added("ports:\n  - \"8080:80\"\n  - \"127.0.0.1:5353:53/udp\"\n  - \"[::1]:9000-9001:9000-9001\"")
                == ["--publish", "8080:80", "--publish", "127.0.0.1:5353:53/udp", "--publish", "[::1]:9000-9001:9000-9001"])
        #expect(try added("environment:\n  B: two words\n  A: \"-1\"\n  EMPTY: \"\"") == ["--env", "A=-1", "--env", "B=two words", "--env", "EMPTY="])
        #expect(try added("working_dir: /srv\nuser: \"1000:1000\"\nplatform: linux/amd64") == ["--workdir", "/srv", "--user", "1000:1000", "--platform", "linux/amd64"])
        #expect(try added("read_only: true\ninit: true\ntty: true") == ["--read-only", "--init", "--tty"])
        #expect(try added("cap_add: [NET_ADMIN]\ncap_drop: [ALL]") == ["--cap-add", "NET_ADMIN", "--cap-drop", "ALL"])
        #expect(try added("shm_size: 64m\ntmpfs:\n  - /run\n  - /tmp:size=16m") == ["--tmpfs", "/run", "--tmpfs", "/tmp:size=16m", "--shm-size", "64m"])
        #expect(try added("ulimits:\n  nofile:\n    soft: 1024\n    hard: 2048\n  nproc: 512") == ["--ulimit", "nofile=1024:2048", "--ulimit", "nproc=512"])
        #expect(try added("sysctls:\n  net.core.somaxconn: 1024") == ["--sysctl", "net.core.somaxconn=1024"])
        #expect(try added("extra_hosts:\n  - \"host.docker.internal:host-gateway\"") == ["--add-host", "host.docker.internal:host-gateway"])
        #expect(try added("dns: 9.9.9.9\ndns_search: example.com\ndns_opt: [\"ndots:2\"]") == ["--dns", "9.9.9.9", "--dns-search", "example.com", "--dns-option", "ndots:2"])
        #expect(try added("restart: unless-stopped") == ["--restart", "unless-stopped"])
        #expect(try added("pull_policy: always") == ["--pull", "always"])
        #expect(try added("pull_policy: missing").isEmpty)
        #expect(try added("labels:\n  team: web\n  note: a=b") == ["--label", "note=a=b", "--label", "team=web"])
    }

    @Test
    func aValueThatLooksLikeAnOptionIsJoinedToItsOption() throws {
        #expect(try added("entrypoint: [\"--weird\"]") == ["--entrypoint=--weird"])
        let (service, _) = try arguments("command: [\"--port\", \"80\"]")
        #expect(service.command == ["--port", "80"], "what follows the image is taken as it is")
    }

    @Test
    func mountsBecomeVolumeAndTmpfsOptions() throws {
        let (service, _) = try arguments(
            """
            volumes:
              - data:/data
              - cache:/cache:ro
              - ./src:/app
              - ~/certs:/certs:ro
              - /scratch
              - type: tmpfs
                target: /run/cache
                tmpfs:
                  size: 64m
            """, extra: "volumes:\n  data:\n  cache:\n    name: shared-cache\n")
        let mounts = service.options.enumerated().filter { ["--volume", "--tmpfs"].contains($0.element) }.map { "\($0.element) \(service.options[$0.offset + 1])" }
        #expect(mounts.count == 6)
        #expect(mounts[0] == "--volume shop_data:/data")
        #expect(mounts[1] == "--volume shared-cache:/cache:ro")
        #expect(mounts[2].hasPrefix("--volume /") && mounts[2].hasSuffix("/shop/src:/app"))
        #expect(mounts[3] == "--volume /Users/tester/certs:/certs:ro")
        #expect(mounts[4] == "--volume /scratch")
        #expect(mounts[5] == "--tmpfs /run/cache:size=64m")
        #expect(service.bindSources.count == 2)
        #expect(service.bindSources[1] == "/Users/tester/certs")
    }

    @Test
    func networksCarryTheServiceNameAsAnAlias() throws {
        #expect(
            try added(
                "networks:\n  front:\n    aliases: [door, web]\n    mac_address: 02:42:ac:11:00:02\n  back:",
                extra: "networks:\n  front:\n  back:\n    name: backplane\n")
                == ["--network", "shop_front,alias=web,alias=door,mac=02:42:ac:11:00:02", "--network", "backplane,alias=web"])

        let project = try TemporaryProject(
            ["compose.yaml": "services:\n  my.service:\n    image: a\n    networks:\n      default:\n        aliases: [\"not valid!\"]\n"], named: "shop")
        let plan = try ProjectPlan.make(try project.load())
        #expect(plan.services[0].options.contains("shop_default,alias=my.service"))
        #expect(plan.warnings.map(\.message) == ["'not valid!' cannot be a name on a network; the other services reach this one as shop-my.service-1"])
    }

    @Test
    func anEntrypointIsOneWordAndTheRestGoesBeforeTheCommand() throws {
        let (both, _) = try arguments("entrypoint: [\"/entry.sh\", \"--verbose\"]\ncommand: serve --port 80")
        #expect(both.options.contains("--entrypoint"))
        #expect(both.command == ["--verbose", "serve", "--port", "80"])
        let (alone, _) = try arguments("entrypoint: /bin/sh -c 'exit 0'")
        #expect(alone.command == ["-c", "exit 0"])
    }

    @Test
    func resourcesAreRoundedToWhatAVirtualMachineCanHave() throws {
        let (service, warnings) = try arguments("cpus: 1.5\nmem_limit: 64m")
        #expect(service.options.contains("--cpus") && service.options[service.options.firstIndex(of: "--cpus")! + 1] == "2")
        #expect(service.options[service.options.firstIndex(of: "--memory")! + 1] == "200m")
        #expect(
            warnings == [
                "compose.yaml:2:3: services.web.cpus: 1.5 becomes 2: a container gets whole CPUs",
                "compose.yaml:2:3: services.web.memory: 64m becomes 200m: a container is a virtual machine, and that is the least one boots with",
            ])
        let (whole, quiet) = try arguments("cpus: 2\nmem_limit: 1gb")
        #expect(quiet.isEmpty)
        #expect(whole.options[whole.options.firstIndex(of: "--cpus")! + 1] == "2")
        #expect(whole.options[whole.options.firstIndex(of: "--memory")! + 1] == "1gb")
    }

    @Test
    func aPortWithNoHostPortIsLeftForCreateToChoose() throws {
        let (service, _) = try arguments("ports:\n  - \"80\"\n  - \"8443:443\"")
        #expect(service.ephemeralPorts == [ComposePort(published: nil, target: "80")])
        #expect(service.options.filter { $0 == "--publish" }.count == 1)
        #expect(service.publishedPorts == ["8443:443", ":80"])
    }

    @Test
    func whatAContainerNeedsToStartAgainTravelsInItsLabels() throws {
        let (service, warnings) = try arguments(
            """
            depends_on:
              db:
                condition: service_healthy
                restart: true
              cache:
                condition: service_started
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost/?probe=1"]
              interval: 10s
            stop_grace_period: 90s
            stop_signal: SIGINT
            restart: always
            """, extra: "  db:\n    image: postgres:16\n    healthcheck:\n      test: pg_isready\n  cache:\n    image: redis:8\n")
        func label(_ key: String) -> String? {
            service.options.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        #expect(label(ComposeLabels.dependsOn) == "cache:service_started:false,db:service_healthy:true")
        #expect(ComposeLabels.dependencies(from: label(ComposeLabels.dependsOn) ?? "") == service.dependencies)
        #expect(ComposeLabels.healthcheck(from: label(ComposeLabels.healthcheck) ?? "") == service.healthcheck)
        #expect(label(ComposeLabels.stopGracePeriod) == "90")
        #expect(service.stopTimeout == 90)
        #expect(service.stopSignal == "SIGINT")
        // The engine honours the policy now, so nothing is said about it.
        #expect(warnings.isEmpty)
        #expect(service.options.contains("--restart"))
    }

    @Test
    func theDigestChangesWithTheContainerAndNotWithWhereTheProjectIs() throws {
        let yaml = "services:\n  web:\n    image: web:1\n    environment:\n      MODE: a\n"
        let first = try TemporaryProject(["compose.yaml": yaml], named: "shop")
        let second = try TemporaryProject(["compose.yaml": yaml], named: "shop")
        let changed = try TemporaryProject(["compose.yaml": yaml.replacingOccurrences(of: "MODE: a", with: "MODE: b")], named: "shop")
        let hash = { (project: TemporaryProject) in try ProjectPlan.make(try project.load()).services[0].configHash }
        #expect(try hash(first) == hash(second))
        #expect(try hash(first) != hash(changed))
    }

    @Test
    func aBuildIsTheCommandThatMakesTheImage() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                services:
                  api:
                    build:
                      context: ./api
                      dockerfile: docker/Dockerfile.dev
                      target: runtime
                      no_cache: true
                      args:
                        VERSION: "1.2"
                      labels:
                        built-by: compose
                      platforms: [linux/arm64]
                  web:
                    image: registry.example.com/shop/web:dev
                    build: .
                """
            ], named: "shop")
        let plan = try ProjectPlan.make(try project.load())
        let api = try #require(plan.service("api"))
        #expect(api.image == "shop-api", "a build with no image name is named after the project and the service")
        #expect(
            api.build?.arguments == [
                "--tag", "shop-api", "--file", "\(project.path)/api/docker/Dockerfile.dev", "--build-arg", "VERSION=1.2", "--target", "runtime",
                "--label", "built-by=compose", "--no-cache", "--platform", "linux/arm64", "\(project.path)/api",
            ])
        let web = try #require(plan.service("web"))
        #expect(web.build?.arguments == ["--tag", "registry.example.com/shop/web:dev", project.path])
    }
}

struct CommandLineTests {
    /// The commands a fixture comes to, with the two things that differ from one checkout to
    /// the next taken out: where the fixture is, and the digests that follow from that.
    private func commands(_ fixture: String, environment: [String: String] = [:], profiles: [String] = []) throws -> [String] {
        let directory = try Fixture.directory(fixture)
        let plan = try ProjectPlan.make(try Fixture.load(fixture, profiles: profiles, environment: environment))
        return plan.commandLines.map { line in
            var line = line.replacingOccurrences(of: directory, with: "$DIR")
            for service in plan.services {
                line = line.replacingOccurrences(of: service.configHash, with: "<digest>")
            }
            return line
        }
    }

    private func expected(_ fixture: String) throws -> [String] {
        let file = URL(fileURLWithPath: try Fixture.directory(fixture)).appendingPathComponent("commands.txt")
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test
    func aHealthCheckIsWrittenAsTheFlagsThatGiveIt() {
        #expect(
            ComposeHealthcheck(test: ["/bin/sh", "-c", "pg_isready -U app"], interval: 90, retries: 5, startPeriod: 0.5).commandLineFlags
                == ["--health-cmd", "pg_isready -U app", "--health-interval", "1m30s", "--health-retries", "5", "--health-start-period", "500ms"])
        #expect(ComposeHealthcheck(test: ["curl", "-f", "http://localhost/?probe=1"]).commandLineFlags == ["--health-cmd", "curl -f 'http://localhost/?probe=1'"])
        #expect(ComposeHealthcheck(timeout: 3).commandLineFlags == ["--health-timeout", "3s"])
        #expect(ComposeHealthcheck.off.commandLineFlags == ["--no-healthcheck"])
    }

    @Test
    func aBotAndItsDatabase() throws {
        #expect(try commands("bot", environment: ["INHERITED": "from-shell", "DB_PASSWORD": "hunter2"]) == expected("bot"))
    }

    @Test
    func anchorsAndProfiles() throws {
        #expect(try commands("anchors", profiles: ["observability"]) == expected("anchors"))
    }

    @Test
    func aStackThatBuildsItsServices() throws {
        #expect(try commands("stack", environment: ["ROUTING_API_KEY": "k"]) == expected("stack"))
    }

    @Test
    func everyLineIsOneTheCommandLineParserTakes() throws {
        for fixture in ["bot", "anchors", "stack"] {
            let plan = try ProjectPlan.make(try Fixture.load(fixture, profiles: ["*"], environment: ["ROUTING_API_KEY": "k"]))
            for service in plan.services {
                let parsed = try RunOptions.parse(service.arguments)
                #expect(parsed.management.name == service.containerName)
                #expect(parsed.image == service.image)
                #expect(parsed.arguments == service.command)
                #expect(try ShellWords.split(ShellWords.join(service.arguments)) == service.arguments)
            }
        }
    }
}
