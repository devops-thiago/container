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

/// Compose files taken from real projects, with their names changed.
struct FixtureTests {
    @Test
    func aBotAndItsDatabase() throws {
        let definition = try Fixture.load("bot", environment: ["INHERITED": "from-shell", "DB_PASSWORD": "hunter2"])
        #expect(definition.name == "bot")
        #expect(definition.warnings.isEmpty)
        #expect(definition.file.volumes.map(\.key) == ["pgdata"])

        let bot = try #require(definition.file.service("bot"))
        #expect(bot.image == "registry.example.com/acme/bot:latest")
        #expect(bot.containerName == "acme-bot")
        #expect(bot.ports == [ComposePort(published: "8080", target: "8080")])
        #expect(bot.restart == "unless-stopped")
        #expect(bot.dependsOn == [ComposeDependency(service: "db", condition: .healthy)])
        #expect(
            bot.environment == [
                // From .env, which the service names as its env_file and compose reads for variables.
                "GITHUB_APP_ID": "12345",
                "WEBHOOK_SECRET": "s3cret value",
                "DB_USER": "botuser",
                "AI_PROVIDER_KEY": "sk-$notavariable",
                "INHERITED": "from-shell",
                // From environment, with the variables substituted.
                "DASHBOARD_URL": "http://localhost:8080",
                "DATASOURCE_DB_KIND": "postgresql",
                "DATABASE_URL": "jdbc:postgresql://db:5432/bot",
                "DATASOURCE_USERNAME": "botuser",
                "DATASOURCE_PASSWORD": "hunter2",
            ])

        let db = try #require(definition.file.service("db"))
        #expect(db.environment == ["POSTGRES_DB": "bot", "POSTGRES_USER": "botuser", "POSTGRES_PASSWORD": "hunter2"])
        #expect(db.mounts == [ComposeMount(kind: .volume(key: "pgdata"), target: "/var/lib/postgresql/data")])
        #expect(db.healthcheck == ComposeHealthcheck(test: ["/bin/sh", "-c", "pg_isready -U botuser -d bot"], interval: 5, timeout: 5, retries: 12))
    }

    @Test
    func aSiteBehindAProxy() throws {
        let environment = [
            "MYSQL_ROOT_PASSWORD": "root", "BLOG_DB_NAME": "blog", "BLOG_DB_USER": "blog", "BLOG_DB_PASSWORD": "pw",
            "BLOG_TABLE_PREFIX": "wp_", "REGISTRY": "registry.example.com", "IMAGE_NAME": "acme/blog", "DOMAIN": "example.org",
        ]
        let definition = try Fixture.load("site", environment: environment)
        #expect(definition.warnings.isEmpty)
        #expect(definition.file.networks.map(\.key) == ["blog", "root_proxy"])
        #expect(definition.file.networks.first { $0.key == "root_proxy" }?.external == true)
        #expect(definition.file.volumes.map(\.key) == ["blog_plugins", "blog_themes", "blog_uploads", "mysql_data"])

        let mysql = try #require(definition.file.service("mysql"))
        #expect(mysql.command == ["--default-authentication-plugin=mysql_native_password"])
        #expect(mysql.networks == [ComposeServiceNetwork(key: "blog")])

        let blog = try #require(definition.file.service("blog"))
        #expect(blog.image == "registry.example.com/acme/blog:latest")
        #expect(blog.networks.map(\.key) == ["root_proxy", "blog"], "networks attach in the order the file lists them")
        #expect(blog.labels["traefik.http.routers.blog.rule"] == "Host(`example.org`)")
        #expect(blog.labels["traefik.http.middlewares.redirect-www.redirectregex.regex"] == "^https?://www\\.(.+)")
        #expect(blog.labels["traefik.http.middlewares.redirect-www.redirectregex.replacement"] == "https://${1}", "$$ is a dollar sign")
        #expect(blog.labels.count == 8)

        let unset = try Fixture.load("site")
        #expect(unset.warnings.count == 8, "one warning for each variable the file uses and nothing sets")
        #expect(unset.warnings.first?.description == "the variable MYSQL_ROOT_PASSWORD is not set; it reads as an empty string")
    }

    @Test
    func aStackThatMountsAFile() throws {
        let directory = try Fixture.directory("observability")
        let errors = loadFailure { try Fixture.load("observability") }
        #expect(
            errors == [
                "compose.yaml:47:5: services.tempo.volumes: not supported on this engine: \(directory)/config/tempo.yaml is a file, and only folders can be mounted. Mount the folder that holds it"
            ])
    }

    @Test
    func anchorsAndProfiles() throws {
        let directory = try Fixture.directory("anchors")
        let definition = try Fixture.load("anchors")
        #expect(definition.file.services.map(\.name) == ["collector", "db", "migrate", "redis", "web", "ws"])
        #expect(definition.file.service("collector")?.profiles == ["observability"])

        let db = try #require(definition.file.service("db"))
        #expect(db.command == ["postgres", "-c", "max_connections=300", "-c", "shared_buffers=512MB"])

        let web = try #require(definition.file.service("web"))
        let ws = try #require(definition.file.service("ws"))
        #expect(web.image == "app-backend:local")
        #expect(web.build == ComposeBuild(context: directory))
        #expect(web.command?.last == "6")
        #expect(web.capDrop == ["ALL"])
        #expect(!web.readOnly)
        #expect(
            web.dependsOn == [
                ComposeDependency(service: "db", condition: .healthy),
                ComposeDependency(service: "migrate", condition: .completedSuccessfully),
                ComposeDependency(service: "redis", condition: .healthy),
            ])
        #expect(
            web.mounts == [
                ComposeMount(kind: .volume(key: "media_data"), target: "/app/media"),
                ComposeMount(kind: .bind(source: "\(directory)/config/root-certs"), target: "/app/root-certs", readOnly: true),
            ])

        // ws is web through a merge key, with its own command and volumes.
        #expect(ws.image == web.image)
        #expect(ws.build == web.build)
        #expect(ws.environment == web.environment)
        #expect(ws.dependsOn == web.dependsOn)
        #expect(ws.restart == "unless-stopped")
        #expect(ws.command?.last == "2")
        #expect(ws.mounts == [ComposeMount(kind: .bind(source: "\(directory)/config/root-certs"), target: "/app/root-certs", readOnly: true)])

        // logging on five services and security_opt on two: each recorded where it is, and
        // said once to a person.
        let ignored = definition.warnings.map(\.path)
        #expect(ignored.filter { $0.hasSuffix(".logging") }.count == 5)
        #expect(ignored.filter { $0.hasSuffix(".security_opt") }.count == 2)
        #expect(definition.warnings.count == 7)
        #expect(
            ComposeDiagnostic.lines(definition.warnings) == [
                "services.{db,redis,migrate,web,ws}.logging: ignored: the engine keeps one log per container, which logs reads",
                "services.{web,ws}.security_opt: ignored: a container is confined by its own virtual machine",
            ])
        #expect(
            ComposeDiagnostic.lines([definition.warnings[0]]) == [
                "compose.yaml:10:5: services.db.logging: ignored: the engine keeps one log per container, which logs reads"
            ], "one of a kind keeps its line")
    }

    @Test
    func aStackThatBuildsItsServices() throws {
        let directory = try Fixture.directory("stack")
        let definition = try Fixture.load("stack", environment: ["ROUTING_API_KEY": "k"])
        #expect(definition.name == "stack")
        #expect(definition.configFiles == ["\(directory)/docker-compose.yml"])
        #expect(definition.warnings.isEmpty)

        let app = try #require(definition.file.service("app"))
        #expect(app.image == nil)
        #expect(app.build == ComposeBuild(context: directory))
        #expect(app.environment == ["ROUTING_API_KEY": "k", "TRAVEL_TIME": "5", "PDF_URL": "http://pdf:3000"])
        #expect(
            app.mounts == [
                ComposeMount(kind: .bind(source: "\(directory)/data"), target: "/data"),
                ComposeMount(kind: .bind(source: "\(directory)/templates"), target: "/app/templates"),
            ])
        #expect(app.dependsOn == [ComposeDependency(service: "db", condition: .healthy), ComposeDependency(service: "pdf")])
        #expect(definition.file.service("frontend")?.build == ComposeBuild(context: "\(directory)/frontend"))
        #expect(definition.file.service("db")?.healthcheck?.test == ["pg_isready", "-U", "postgres"])
    }
}

struct ConfigOutputTests {
    /// What the files describe, without where they say it or whether they name the project.
    private func withoutLocations(_ file: ComposeFile) -> ComposeFile {
        var file = file
        file.name = nil
        file.services = file.services.map { service in
            var service = service
            service.location = nil
            return service
        }
        return file
    }

    @Test(arguments: ["bot", "site", "anchors", "stack", "override"])
    func theRenderedProjectReadsBackAsTheSameProject(_ fixture: String) throws {
        let environment = [
            "INHERITED": "from-shell", "DB_PASSWORD": "pa$$word", "ROUTING_API_KEY": "k", "DOMAIN": "example.org", "REGISTRY": "registry.example.com",
            "IMAGE_NAME": "acme/blog",
        ]
        let original = try Fixture.load(fixture, profiles: ["*"], environment: environment)
        let rendered = try original.yaml()
        let project = try TemporaryProject(["compose.yaml": rendered], named: "elsewhere")
        let reread = try project.load()
        #expect(reread.name == original.name, "the name travels in the file")
        #expect(withoutLocations(reread.file) == withoutLocations(original.file))
        #expect(reread.warnings.isEmpty, "nothing in the rendered file is ignored or left unset")
    }

    @Test
    func theRenderedProjectIsWhatTheFilesComeTo() throws {
        let project = try TemporaryProject(
            [
                "compose.yaml": """
                services:
                  web:
                    image: web:${TAG:-1}
                    command: serve --port 80
                    ports: ["8080:80"]
                    environment:
                      PRICE: $$5
                    healthcheck:
                      test: curl -f localhost
                      interval: 90s
                      start_interval: 500ms
                    stop_grace_period: 1h1m1s
                """
            ], named: "shop")
        let rendered = try project.load().yaml()
        let expected = """
            name: shop
            services:
              web:
                command:
                - serve
                - --port
                - '80'
                environment:
                  PRICE: $$5
                healthcheck:
                  interval: 1m30s
                  retries: 3
                  start_interval: 500ms
                  test:
                  - CMD
                  - /bin/sh
                  - -c
                  - curl -f localhost
                  timeout: 30s
                image: web:1
                ports:
                - protocol: tcp
                  published: '8080'
                  target: '80'
                stop_grace_period: 1h1m1s

            """
        #expect(rendered == expected)
    }

    @Test(arguments: [(0.0, "0s"), (5.0, "5s"), (90.0, "1m30s"), (3600.0, "1h"), (3661.0, "1h1m1s"), (0.5, "500ms"), (1.25, "1250ms")])
    func durationsAreWrittenTheWayTheyAreRead(_ seconds: Double, _ text: String) {
        #expect(ComposeDefinition.duration(seconds) == text)
        #expect(DecodeContext.seconds(text) == seconds)
    }
}
