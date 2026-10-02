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

struct PortTests {
    private func port(_ spec: String) -> (port: ComposePort?, errors: [String]) {
        let diagnostics = DiagnosticCollector()
        let context = DecodeContext(projectDirectory: URL(fileURLWithPath: "/project"), homeDirectory: "/Users/tester", diagnostics: diagnostics)
        let port = context.shortPort(spec, "ports[0]", at: SourceLocation(file: "compose.yaml", line: 1, column: 1))
        return (port, diagnostics.errors.map(\.message))
    }

    @Test(arguments: [
        ("3000", ComposePort(published: nil, target: "3000")),
        ("8000:8000", ComposePort(published: "8000", target: "8000")),
        ("49100:22", ComposePort(published: "49100", target: "22")),
        ("9090-9091:8080-8081", ComposePort(published: "9090-9091", target: "8080-8081")),
        ("127.0.0.1:8001:8001", ComposePort(hostIP: "127.0.0.1", published: "8001", target: "8001")),
        ("127.0.0.1:5000-5010:5000-5010", ComposePort(hostIP: "127.0.0.1", published: "5000-5010", target: "5000-5010")),
        ("127.0.0.1::5432", ComposePort(hostIP: "127.0.0.1", published: nil, target: "5432")),
        ("6060:6060/udp", ComposePort(published: "6060", target: "6060", transport: .udp)),
        ("53:53/UDP", ComposePort(published: "53", target: "53", transport: .udp)),
        ("[::1]:6001:6001", ComposePort(hostIP: "::1", published: "6001", target: "6001")),
        ("[::1]:6001:6001/udp", ComposePort(hostIP: "::1", published: "6001", target: "6001", transport: .udp)),
    ])
    func reads(_ spec: String, _ expected: ComposePort) {
        let result = port(spec)
        #expect(result.port == expected)
        #expect(result.errors.isEmpty)
    }

    @Test(arguments: [
        ("http", "is not a port or a range of ports"),
        ("0:80", "is not a port or a range of ports"),
        ("80:70000", "is not a port or a range of ports"),
        ("9000-8000:80", "is not a port or a range of ports"),
        ("8000-8010:80", "have to be the same size"),
        ("8000-8001:80-82", "have to be the same size"),
        ("3000-3005", "needs a range of host ports"),
        ("80:80/sctp", "the protocol is tcp or udp"),
        ("::1:80:80", "write an IPv6 address in brackets"),
        ("[::1:80:80", "never closed"),
        ("[::1]:80", "followed by a host port and a container port"),
    ])
    func refuses(_ spec: String, _ reason: String) {
        let result = port(spec)
        #expect(result.port == nil)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains(reason) == true, "\(result.errors)")
    }

    @Test
    func theLongFormSaysTheSame() throws {
        let service = try loadService(
            """
            ports:
              - target: 80
                published: "8080"
                host_ip: 127.0.0.1
                protocol: udp
                mode: host
              - target: 443
              - name: web
                target: 8000-8001
                published: 9000-9001
                app_protocol: http
              - 5000:5000
            """)
        #expect(
            service.ports == [
                ComposePort(hostIP: "127.0.0.1", published: "8080", target: "80", transport: .udp),
                ComposePort(published: nil, target: "443"),
                ComposePort(published: "9000-9001", target: "8000-8001"),
                ComposePort(published: "5000", target: "5000"),
            ])
    }
}

struct MountTests {
    private func mount(_ spec: String) -> (mount: ComposeMount?, errors: [String]) {
        let diagnostics = DiagnosticCollector()
        let context = DecodeContext(projectDirectory: URL(fileURLWithPath: "/project"), homeDirectory: "/Users/tester", diagnostics: diagnostics)
        let mount = context.shortMount(spec, "volumes[0]", at: SourceLocation(file: "compose.yaml", line: 1, column: 1))
        return (mount, diagnostics.errors.map(\.message))
    }

    @Test(arguments: [
        ("/var/lib/mysql", ComposeMount(kind: .anonymous, target: "/var/lib/mysql")),
        ("/scratch:ro", ComposeMount(kind: .anonymous, target: "/scratch", readOnly: true)),
        ("/opt/data:/var/lib/mysql", ComposeMount(kind: .bind(source: "/opt/data"), target: "/var/lib/mysql")),
        ("./cache:/tmp/cache", ComposeMount(kind: .bind(source: "/project/cache"), target: "/tmp/cache")),
        (".:/src", ComposeMount(kind: .bind(source: "/project"), target: "/src")),
        ("../shared:/shared:ro", ComposeMount(kind: .bind(source: "/shared"), target: "/shared", readOnly: true)),
        ("~/configs:/etc/configs/:ro", ComposeMount(kind: .bind(source: "/Users/tester/configs"), target: "/etc/configs", readOnly: true)),
        ("datavolume:/var/lib/mysql", ComposeMount(kind: .volume(key: "datavolume"), target: "/var/lib/mysql")),
        ("datavolume:/var/lib/mysql:rw,z", ComposeMount(kind: .volume(key: "datavolume"), target: "/var/lib/mysql")),
        ("./src:/app:cached", ComposeMount(kind: .bind(source: "/project/src"), target: "/app")),
    ])
    func reads(_ spec: String, _ expected: ComposeMount) {
        let result = mount(spec)
        #expect(result.mount == expected)
        #expect(result.errors.isEmpty)
    }

    @Test(arguments: [
        ("data:relative/path", "has to be absolute"),
        ("relative", "has to be absolute"),
        ("a:/b:ro:extra", "expected [source:]target[:mode]"),
        ("data:/data:fast", "'fast' is not a mount option"),
    ])
    func refuses(_ spec: String, _ reason: String) {
        let result = mount(spec)
        #expect(result.mount == nil)
        #expect(result.errors.first?.contains(reason) == true, "\(result.errors)")
    }

    @Test
    func theLongFormSaysTheSame() throws {
        let service = try loadService(
            """
            volumes:
              - type: volume
                source: data
                target: /data
                volume:
                  nocopy: true
              - type: bind
                source: ./conf
                target: /etc/app/
                read_only: true
                bind:
                  create_host_path: true
              - type: tmpfs
                target: /run/cache
                tmpfs:
                  size: 64m
              - type: volume
                target: /scratch
            """, extra: "volumes:\n  data:\n")
        #expect(service.mounts.count == 4)
        #expect(service.mounts[0] == ComposeMount(kind: .volume(key: "data"), target: "/data"))
        #expect(service.mounts[1].target == "/etc/app")
        #expect(service.mounts[1].readOnly)
        if case .bind(let source) = service.mounts[1].kind {
            #expect(source.hasSuffix("/conf"))
        } else {
            Issue.record("expected a bind mount")
        }
        #expect(service.mounts[2] == ComposeMount(kind: .tmpfs(size: "64m"), target: "/run/cache"))
        #expect(service.mounts[3] == ComposeMount(kind: .anonymous, target: "/scratch"))
    }

    @Test
    func aVolumeHasToBeDeclared() throws {
        let result = try diagnose("volumes:\n  - data:/data")
        #expect(result.errors == ["compose.yaml:4:5: services.web.volumes: the volume 'data' is not defined under the top-level volumes"])
    }

    @Test
    func aFileIsNotMountedOnlyAFolder() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:1\n    volumes:\n      - ./nginx.conf:/etc/nginx/nginx.conf:ro\n      - ./html:/usr/share/nginx/html\n",
            "nginx.conf": "events {}\n",
        ])
        try project.makeDirectory("html")
        let errors = loadFailure { try project.load() }
        #expect(errors.count == 1)
        #expect(errors.first?.contains("\(project.path)/nginx.conf is a file, and only folders can be mounted") == true, "\(errors)")
    }
}

struct ServiceSettingTests {
    @Test
    func commandsAreListsOrStringsSplitLikeAShell() throws {
        let service = try loadService(
            """
            command: bundle exec thin -p 3000 --name "my app"
            entrypoint: ["/entry.sh", "--verbose"]
            """)
        #expect(service.command == ["bundle", "exec", "thin", "-p", "3000", "--name", "my app"])
        #expect(service.entrypoint == ["/entry.sh", "--verbose"])
        #expect(try diagnose("command: \"an 'open quote\"").errors == ["compose.yaml:4:14: services.web.command: a quote (') is opened and never closed"])
    }

    @Test
    func theEnvironmentIsEnvFilesThenEnvironment() throws {
        let project = try TemporaryProject([
            "compose.yaml": """
            services:
              web:
                image: web:1
                env_file:
                  - common.env
                  - path: local.env
                    required: false
                  - path: absent.env
                    required: false
                environment:
                  - FROM_BOTH=environment
                  - INHERITED
                  - NOT_SET_ANYWHERE
                  - EMPTY=
            """,
            "common.env": "FROM_FILE=common\nFROM_BOTH=common\nOVERRIDDEN=common\nPASSED_THROUGH\n",
            "local.env": "OVERRIDDEN=local\n",
        ])
        let service = try #require(try project.load(environment: ["INHERITED": "from-shell", "PASSED_THROUGH": "also"]).file.service("web"))
        #expect(
            service.environment == [
                "FROM_FILE": "common",
                "FROM_BOTH": "environment",
                "OVERRIDDEN": "local",
                "PASSED_THROUGH": "also",
                "INHERITED": "from-shell",
                "EMPTY": "",
            ])
    }

    @Test
    func theProjectsEnvFileCountsAsTheEnvironment() throws {
        let project = try TemporaryProject([
            "compose.yaml": "services:\n  web:\n    image: web:1\n    env_file: service.env\n    environment:\n      - REGION\n",
            ".env": "REGION=eu\nTIER=gold\n",
            "service.env": "PLAN=${TIER}\n",
        ])
        #expect(try project.load().file.service("web")?.environment == ["REGION": "eu", "PLAN": "gold"])
    }

    @Test
    func aMissingEnvFileIsAnErrorUnlessItIsOptional() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    image: web:1\n    env_file: absent.env\n"])
        #expect(loadFailure { try project.load() } == ["compose.yaml:4:15: services.web.env_file: \(project.path)/absent.env does not exist"])
    }

    @Test
    func aMappingEnvironmentKeepsNumbersAndBooleansAsText() throws {
        let service = try loadService(
            """
            environment:
              PORT: 8080
              DEBUG: true
              RATIO: 1.50
              QUOTED: "yes"
              BLANK: ""
              UNSET_HERE:
            """, environment: ["UNSET_HERE": "taken"])
        #expect(service.environment == ["PORT": "8080", "DEBUG": "true", "RATIO": "1.50", "QUOTED": "yes", "BLANK": "", "UNSET_HERE": "taken"])
    }

    @Test
    func dependenciesAreNamesOrConditions() throws {
        let extra = """
              db:
                image: postgres:16
                healthcheck:
                  test: pg_isready
              init:
                image: busybox
              cache:
                image: redis:8
            """
        let short = try loadService("depends_on:\n  - db\n  - cache", extra: extra)
        #expect(short.dependsOn == [ComposeDependency(service: "cache"), ComposeDependency(service: "db")])

        let long = try loadService(
            """
            depends_on:
              db:
                condition: service_healthy
                restart: true
              init:
                condition: service_completed_successfully
              cache:
                required: false
            """, extra: extra)
        #expect(
            long.dependsOn == [
                ComposeDependency(service: "cache", required: false),
                ComposeDependency(service: "db", condition: .healthy, restart: true),
                ComposeDependency(service: "init", condition: .completedSuccessfully),
            ])
    }

    @Test
    func aDependencyHasToExistAndToBeCheckable() throws {
        #expect(try diagnose("depends_on:\n  - ghost").errors == ["compose.yaml:4:5: services.web.depends_on.ghost: there is no service named 'ghost'"])
        #expect(try diagnose("depends_on:\n  - web").errors == ["compose.yaml:4:5: services.web.depends_on.web: a service cannot depend on itself"])
        let unhealthy = try diagnose("depends_on:\n  db:\n    condition: service_healthy", extra: "  db:\n    image: postgres:16\n")
        #expect(unhealthy.errors.count == 1)
        #expect(unhealthy.errors.first?.contains("that service has no healthcheck with a test") == true)
        #expect(
            try diagnose("depends_on:\n  db:\n    condition: service_ready", extra: "  db:\n    image: postgres:16\n").errors.first?.contains("expected service_started") == true)
    }

    @Test
    func aHealthcheckIsACommandAndItsTiming() throws {
        let service = try loadService(
            """
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 1m30s
              timeout: 10s
              retries: 5
              start_period: 40s
              start_interval: 500ms
            """)
        #expect(
            service.healthcheck
                == ComposeHealthcheck(
                    test: ["curl", "-f", "http://localhost"], interval: 90, timeout: 10, retries: 5, startPeriod: 40, startInterval: 0.5))
        #expect(try loadService("healthcheck:\n  test: curl -f http://localhost || exit 1").healthcheck?.test == ["/bin/sh", "-c", "curl -f http://localhost || exit 1"])
        #expect(try loadService("healthcheck:\n  test: [\"CMD-SHELL\", \"pg_isready -U app\"]").healthcheck?.test == ["/bin/sh", "-c", "pg_isready -U app"])
        #expect(try loadService("healthcheck:\n  test: [\"NONE\"]").healthcheck == nil)
        #expect(try loadService("healthcheck:\n  disable: true\n  test: curl localhost").healthcheck == nil)
        #expect(try diagnose("healthcheck:\n  test: [\"curl\", \"localhost\"]").errors.first?.contains("starts with CMD and a command") == true)

        let timingOnly = try diagnose("healthcheck:\n  interval: 5s")
        #expect(timingOnly.errors.isEmpty)
        #expect(timingOnly.warnings.first?.contains("services.web.healthcheck: ignored: it has no test") == true)
    }

    @Test(arguments: [
        ("30s", 30.0), ("1m30s", 90.0), ("2h", 7200.0), ("500ms", 0.5), ("1h2m3s", 3723.0), ("0", 0.0), ("45", 45.0), ("1.5s", 1.5), ("1d", 86400.0),
    ])
    func durations(_ text: String, _ seconds: Double) {
        #expect(DecodeContext.seconds(text) == seconds)
    }

    @Test(arguments: ["", "soon", "10x", "s", "-5s", "1m 30s"])
    func notDurations(_ text: String) {
        #expect(DecodeContext.seconds(text) == nil)
    }

    @Test
    func theRestOfAService() throws {
        let service = try loadService(
            """
            container_name: front.door_1
            hostname: front
            restart: on-failure:3
            pull_policy: if_not_present
            working_dir: /srv
            user: "1000:1000"
            platform: linux/amd64
            labels:
              com.example.team: web
              com.example.empty:
            tmpfs: /run
            ulimits:
              nproc: 65535
              nofile:
                soft: 20000
                hard: 40000
            cap_add: [NET_ADMIN]
            cap_drop:
              - ALL
            read_only: true
            init: true
            tty: true
            shm_size: 64M
            dns: 9.9.9.9
            dns_search: [example.com, internal]
            dns_opt:
              - ndots:2
            stop_signal: SIGINT
            stop_grace_period: 1m
            cpus: 1.5
            mem_limit: 512m
            sysctls:
              - net.core.somaxconn=1024
            extra_hosts:
              - "gateway:host-gateway"
              - "six=[::1]"
              - "four:10.0.0.4"
            profiles: [debug]
            networks:
              front:
                aliases: [door, entry]
              back:
            mac_address: 02:42:ac:11:00:02
            """, extra: "networks:\n  front:\n  back:\n")
        #expect(service.containerName == "front.door_1")
        #expect(service.hostname == "front")
        #expect(service.restart == "on-failure:3")
        #expect(service.pullPolicy == .missing)
        #expect(service.workingDirectory == "/srv")
        #expect(service.user == "1000:1000")
        #expect(service.platform == "linux/amd64")
        #expect(service.labels == ["com.example.team": "web", "com.example.empty": ""])
        #expect(service.tmpfs == ["/run"])
        #expect(service.ulimits == [ComposeUlimit(name: "nofile", soft: "20000", hard: "40000"), ComposeUlimit(name: "nproc", soft: "65535")])
        #expect(service.capAdd == ["NET_ADMIN"])
        #expect(service.capDrop == ["ALL"])
        #expect(service.readOnly && service.useInit && service.tty)
        #expect(service.shmSize == "64m")
        #expect(service.dns == ["9.9.9.9"])
        #expect(service.dnsSearch == ["example.com", "internal"])
        #expect(service.dnsOptions == ["ndots:2"])
        #expect(service.stopSignal == "SIGINT")
        #expect(service.stopGracePeriod == 60)
        #expect(service.cpus == 1.5)
        #expect(service.memory == "512m")
        #expect(service.sysctls == ["net.core.somaxconn": "1024"])
        #expect(service.extraHosts == ["gateway:host-gateway", "six:::1", "four:10.0.0.4"])
        #expect(service.profiles == ["debug"])
        #expect(
            service.networks == [
                ComposeServiceNetwork(key: "front", aliases: ["door", "entry"], macAddress: "02:42:ac:11:00:02"),
                ComposeServiceNetwork(key: "back"),
            ])
    }

    @Test
    func deployLimitsAreTheServiceLimits() throws {
        let service = try loadService(
            """
            deploy:
              replicas: 1
              resources:
                limits:
                  cpus: "2"
                  memory: 1gb
                reservations:
                  memory: 256m
              restart_policy:
                condition: on-failure
            """)
        #expect(service.cpus == 2)
        #expect(service.memory == "1gb")
        let diagnosis = try diagnose("deploy:\n  replicas: 3\n  placement:\n    constraints: []")
        #expect(diagnosis.errors == ["compose.yaml:5:7: services.web.deploy.replicas: not supported on this engine: a service runs as one container"])
    }

    @Test
    func aServiceNeedsSomethingToRun() throws {
        let project = try TemporaryProject(["compose.yaml": "services:\n  web:\n    command: serve\n"])
        #expect(loadFailure { try project.load() } == ["compose.yaml:2:3: services.web: a service needs an image, or a build that makes one"])
        let empty = try TemporaryProject(["compose.yaml": "name: nothing\n"])
        #expect(loadFailure { try empty.load() } == ["services: the project has no services"])
    }

    @Test
    func aBuildIsAContextAndHowToBuildIt() throws {
        let project = try TemporaryProject([
            "compose.yaml": """
            services:
              short:
                build: ./app
              long:
                image: registry.example.com/long:dev
                build:
                  context: .
                  dockerfile: docker/Dockerfile.dev
                  target: runtime
                  no_cache: true
                  args:
                    VERSION: "1.2"
                    FROM_SHELL:
                    NOT_SET:
                  labels:
                    - built-by=compose
                  platforms: [linux/arm64]
                  cache_from:
                    - registry.example.com/long:cache
            """
        ])
        let definition = try project.load(environment: ["FROM_SHELL": "yes"])
        let short = try #require(definition.file.service("short")?.build)
        #expect(short == ComposeBuild(context: "\(project.path)/app"))

        let long = try #require(definition.file.service("long")?.build)
        #expect(long.context == project.path)
        #expect(long.dockerfile == "docker/Dockerfile.dev")
        #expect(long.target == "runtime")
        #expect(long.noCache)
        #expect(long.args == ["VERSION": "1.2", "FROM_SHELL": "yes"])
        #expect(long.labels == ["built-by": "compose"])
        #expect(long.platforms == ["linux/arm64"])
        #expect(definition.warnings.map(\.description) == ["compose.yaml:18:7: services.long.build.cache_from: ignored: the builder keeps its own cache"])
    }
}

struct KeySupportTests {
    @Test
    func aKeyComposeDoesNotHaveIsToldApartFromOneTheEngineCannotHonour() throws {
        let result = try diagnose(
            """
            privileged: true
            devices:
              - /dev/ttyUSB0:/dev/ttyUSB0
            network_mode: host
            imagee: typo
            x-anything: passes
            """)
        #expect(
            result.errors == [
                "compose.yaml:4:5: services.web.privileged: not supported on this engine: a container already has its own kernel; add the capabilities it needs with cap_add",
                "compose.yaml:5:5: services.web.devices: not supported on this engine: host devices are not passed to containers",
                "compose.yaml:7:5: services.web.network_mode: not supported on this engine: a container attaches to networks; the host's, none, and another container's are not available",
                "compose.yaml:8:5: services.web.imagee: not a compose key",
            ])
    }

    @Test(arguments: [
        "cgroup: host", "configs: [app]", "credential_spec: {}", "device_cgroup_rules: ['c 1:3 mr']", "extends: {service: base}",
        "gpus: all", "ipc: host", "pid: host", "post_start: []", "pre_stop: []", "runtime: runc", "secrets: [token]",
        "userns_mode: host", "uts: host", "volumes_from: [other]", "scale: 2",
    ])
    func refusedWithTheKeyNamed(_ setting: String) throws {
        let key = String(setting.prefix { $0 != ":" })
        let result = try diagnose(setting)
        #expect(result.errors.count == 1, "\(result.errors)")
        #expect(result.errors.first?.hasPrefix("compose.yaml:4:5: services.web.\(key): not supported on this engine") == true, "\(result.errors)")
    }

    @Test(arguments: [
        "logging: {driver: json-file}", "security_opt: ['no-new-privileges:true']", "expose: ['3000']", "stdin_open: true",
        "oom_score_adj: 100", "oom_kill_disable: true", "cgroup_parent: m-executor", "attach: false", "links: [db]",
        "cpu_shares: 512", "mem_reservation: 128m", "pids_limit: 100", "develop: {watch: []}", "annotations: {a: b}",
    ])
    func ignoredWithOneWarning(_ setting: String) throws {
        let key = String(setting.prefix { $0 != ":" })
        let result = try diagnose(setting)
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.warnings.count == 1, "\(result.warnings)")
        #expect(result.warnings.first?.hasPrefix("compose.yaml:4:5: services.web.\(key): ignored: ") == true, "\(result.warnings)")
    }

    @Test
    func settingsThatAskForNothingPass() throws {
        let result = try diagnose("privileged: false\nscale: 1\ndeploy:\n  replicas: 1")
        #expect(result.errors.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func everythingWrongIsReportedAtOnce() throws {
        let project = try TemporaryProject([
            "compose.yaml": """
            version: "3.9"
            secrets:
              token:
                file: ./token
            services:
              web:
                image: web:1
                pid: host
                ports:
                  - "eighty"
                restart: sometimes
              worker:
                build: https://github.com/example/worker.git
                volumes:
                  - type: npipe
                    source: pipe
                    target: /pipe
            networks:
              wide:
                driver: overlay
            volumes:
              nfs:
                driver: nfs
            """
        ])
        let errors = loadFailure { try project.load() }
        #expect(
            errors == [
                "compose.yaml:2:1: secrets: not supported on this engine: mount a folder that holds the file, or pass the value in environment",
                "compose.yaml:8:5: services.web.pid: not supported on this engine: a container has its own kernel and namespaces",
                "compose.yaml:10:9: services.web.ports[0]: 'eighty' is not a port mapping: 'eighty' is not a port or a range of ports",
                "compose.yaml:11:14: services.web.restart: expected no, always, unless-stopped or on-failure[:retries], found 'sometimes'",
                "compose.yaml:13:12: services.worker.build: not supported on this engine: a build context has to be a folder on this Mac",
                "compose.yaml:15:9: services.worker.volumes[0].type: not supported on this engine: a mount is a bind, a volume or a tmpfs",
                "compose.yaml:20:5: networks.wide.driver: not supported on this engine: networks are of one kind, which compose calls bridge",
                "compose.yaml:23:5: volumes.nfs.driver: not supported on this engine: volumes are local disk images",
            ], "top to bottom, the way the file reads")
    }

    @Test
    func networksAndVolumesSayWhatTheyAre() throws {
        let project = try TemporaryProject([
            "compose.yaml": """
            services:
              web:
                image: web:1
            networks:
              default:
                name: shared-net
                external: true
              back:
                internal: true
                driver: bridge
                attachable: true
                ipam:
                  driver: default
                  config:
                    - subnet: 172.28.0.0/16
                      gateway: 172.28.0.1
                labels:
                  tier: data
              old:
                external:
                  name: legacy-net
            volumes:
              data:
                name: shared-data
                labels: {keep: "yes"}
              theirs:
                external: true
            """
        ])
        let definition = try project.load()
        let networks = Dictionary(uniqueKeysWithValues: definition.file.networks.map { ($0.key, $0) })
        #expect(networks["default"]?.name == "shared-net")
        #expect(networks["default"]?.external == true)
        #expect(networks["back"]?.isInternal == true)
        #expect(networks["back"]?.subnet == "172.28.0.0/16")
        #expect(networks["back"]?.labels == ["tier": "data"])
        #expect(networks["old"]?.external == true)
        #expect(networks["old"]?.name == "legacy-net")
        let volumes = Dictionary(uniqueKeysWithValues: definition.file.volumes.map { ($0.key, $0) })
        #expect(volumes["data"]?.name == "shared-data")
        #expect(volumes["data"]?.labels == ["keep": "yes"])
        #expect(volumes["theirs"]?.external == true)
        #expect(
            definition.warnings.map(\.description) == [
                "compose.yaml:11:5: networks.back.attachable: ignored: any container can attach to a network",
                "compose.yaml:16:11: networks.back.ipam.config[0].gateway: ignored: the gateway is the first address of the subnet",
            ])
    }

    @Test
    func aStaticAddressIsRefused() throws {
        let result = try diagnose("networks:\n  back:\n    ipv4_address: 172.28.0.10", extra: "networks:\n  back:\n")
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.hasPrefix("compose.yaml:6:9: services.web.networks.back.ipv4_address: not supported on this engine") == true, "\(result.errors)")
    }

    @Test
    func aNetworkHasToBeDeclared() throws {
        #expect(try diagnose("networks:\n  - nowhere").errors == ["compose.yaml:4:5: services.web.networks: the network 'nowhere' is not defined under the top-level networks"])
        #expect(try diagnose("networks:\n  - default").errors.isEmpty)
    }
}
