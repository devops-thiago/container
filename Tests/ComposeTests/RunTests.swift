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

struct UpTests {
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
            volumes:
              - data:/var/lib/postgresql/data
            healthcheck:
              test: pg_isready
              interval: 5s
              retries: 3
          cache:
            image: redis:8
        volumes:
          data:
        """

    private func failure(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test
    func everythingIsMadeBeforeAnythingStarts() async throws {
        let run = ComposeRun()
        try await run.project().up(try run.plan(Self.chain))
        #expect(
            run.engine.calls == [
                "network create shop_default",
                "volume create shop_data",
                "create shop-cache-1", "create shop-db-1", "create shop-api-1", "create shop-web-1",
                "start shop-cache-1", "start shop-db-1",
                "probe shop-db-1",
                "start shop-api-1", "start shop-web-1",
            ], "every container exists, and so has its address, before the first one starts")
        #expect(
            run.recorder.events == [
                "network shop_default creating", "network shop_default created",
                "volume shop_data creating", "volume shop_data created",
                "container shop-cache-1 creating", "container shop-cache-1 created",
                "container shop-db-1 creating", "container shop-db-1 created",
                "container shop-api-1 creating", "container shop-api-1 created",
                "container shop-web-1 creating", "container shop-web-1 created",
                "container shop-cache-1 starting", "container shop-cache-1 started",
                "container shop-db-1 starting", "container shop-db-1 started",
                "container shop-db-1 waiting (to be healthy)", "container shop-db-1 healthy",
                "container shop-api-1 starting", "container shop-api-1 started",
                "container shop-web-1 starting", "container shop-web-1 started",
            ])
        #expect(run.recorder.warnings.isEmpty)
    }

    @Test
    func aSecondUpChangesNothing() async throws {
        let run = ComposeRun()
        let plan = try run.plan(Self.chain)
        try await run.project().up(plan)
        run.engine.clearCalls()
        try await run.project().up(plan)
        #expect(run.engine.calls == ["probe shop-db-1"], "nothing is made or started again; the dependency is still checked")
        #expect(
            run.recorder.events.suffix(6) == [
                "container shop-cache-1 running", "container shop-db-1 running",
                "container shop-db-1 waiting (to be healthy)", "container shop-db-1 healthy",
                "container shop-api-1 running", "container shop-web-1 running",
            ])
    }

    @Test
    func aStoppedProjectIsStartedNotMadeAgain() async throws {
        let run = ComposeRun()
        let plan = try run.plan(Self.chain)
        try await run.project().up(plan)
        try await run.project().stop()
        run.engine.clearCalls()
        try await run.project().up(plan)
        #expect(run.engine.calls == ["start shop-cache-1", "start shop-db-1", "probe shop-db-1", "start shop-api-1", "start shop-web-1"])
    }

    @Test
    func aServiceThatChangedIsMadeAgainAndOnlyThatOne() async throws {
        let run = ComposeRun()
        try await run.project().up(try run.plan(Self.chain))
        run.engine.clearCalls()
        let changed = try run.plan(Self.chain.replacingOccurrences(of: "image: api:1", with: "image: api:2"))
        try await run.project().up(changed)
        #expect(run.engine.calls == ["stop shop-api-1", "remove shop-api-1", "create shop-api-1", "probe shop-db-1", "start shop-api-1"])
        #expect(run.recorder.events.contains("container shop-api-1 recreating"))
        #expect(run.engine.arguments(of: "shop-api-1").contains("api:2"))
    }

    @Test
    func recreationCanBeForcedOrHeldBack() async throws {
        let run = ComposeRun()
        let plan = try run.plan("services:\n  web:\n    image: web:1\n")
        try await run.project().up(plan)
        run.engine.clearCalls()

        var force = ComposeProject.UpOptions()
        force.forceRecreate = true
        try await run.project().up(plan, options: force)
        #expect(run.engine.calls == ["stop shop-web-1", "remove shop-web-1", "create shop-web-1", "start shop-web-1"])
        run.engine.clearCalls()

        var hold = ComposeProject.UpOptions()
        hold.noRecreate = true
        try await run.project().up(try run.plan("services:\n  web:\n    image: web:2\n"), options: hold)
        #expect(run.engine.calls.isEmpty)
        #expect(run.engine.arguments(of: "shop-web-1").contains("web:1"))
    }

    @Test
    func createOnlyStopsBeforeStarting() async throws {
        let run = ComposeRun()
        var options = ComposeProject.UpOptions()
        options.start = false
        try await run.project().up(try run.plan(Self.chain), options: options)
        #expect(!run.engine.calls.contains { $0.hasPrefix("start") })
        #expect(run.engine.containerNames == ["shop-api-1", "shop-cache-1", "shop-db-1", "shop-web-1"])
    }

    @Test
    func aDependentWaitsForItsDependencyToBeHealthy() async throws {
        let run = ComposeRun()
        run.engine.probes["shop-db-1"] = [1, nil, 0]
        try await run.project().up(try run.plan(Self.chain))
        let calls = run.engine.calls
        let firstProbe = try #require(calls.firstIndex(of: "probe shop-db-1"))
        let apiStart = try #require(calls.firstIndex(of: "start shop-api-1"))
        #expect(calls.filter { $0 == "probe shop-db-1" }.count == 3)
        #expect(firstProbe < apiStart)
        #expect(run.clock.now == 2, "it looked again every second, not every interval")
    }

    @Test
    func aDependencyThatNeverGetsHealthyStopsTheRun() async throws {
        let run = ComposeRun()
        run.engine.probes["shop-db-1"] = [7]
        let message = await failure { try await run.project().up(try run.plan(Self.chain)) }
        #expect(
            message
                == "service db is not healthy after 15 seconds: its check (/bin/sh -c pg_isready) keeps failing; the last time, it ended with exit code 7"
        )
        #expect(!run.engine.calls.contains("start shop-api-1"))
        #expect(!run.engine.calls.contains("start shop-web-1"))
        #expect(run.recorder.events.last?.hasPrefix("container shop-db-1 failed (service db is not healthy after 15 seconds") == true)
    }

    @Test
    func aCheckThatHangsIsAFailedCheck() async throws {
        let run = ComposeRun()
        run.engine.probes["shop-db-1"] = [nil]
        let message = await failure { try await run.project().up(try run.plan(Self.chain)) }
        #expect(message.hasSuffix("the last time, it did not finish within 30 seconds"))
    }

    @Test
    func aDependencyThatStopsCannotBecomeHealthy() async throws {
        let run = ComposeRun()
        run.engine.exits["shop-db-1"] = 3
        let message = await failure { try await run.project().up(try run.plan(Self.chain)) }
        #expect(message == "service db cannot become healthy: its container shop-db-1 has stopped with exit code 3")
    }

    private static let migration = """
        services:
          web:
            image: web:1
            depends_on:
              migrate:
                condition: service_completed_successfully
          migrate:
            image: web:1
            command: migrate
        """

    @Test
    func aDependentWaitsForAOneShotToFinish() async throws {
        let run = ComposeRun()
        run.engine.exitsLater["shop-migrate-1"] = (looks: 2, code: 0)
        try await run.project().up(try run.plan(Self.migration))
        #expect(run.engine.calls == ["network create shop_default", "create shop-migrate-1", "create shop-web-1", "start shop-migrate-1", "start shop-web-1"])
        #expect(
            run.recorder.events.suffix(6) == [
                "container shop-migrate-1 starting", "container shop-migrate-1 started",
                "container shop-migrate-1 waiting (to finish)", "container shop-migrate-1 completed",
                "container shop-web-1 starting", "container shop-web-1 started",
            ])
        run.engine.exits["shop-migrate-1"] = 0

        // While what waited for it runs, the job has done its work and is left alone.
        run.engine.clearCalls()
        try await run.project().up(try run.plan(Self.migration))
        #expect(run.engine.calls.isEmpty)
        #expect(
            run.recorder.events.suffix(2) == ["container shop-migrate-1 completed", "container shop-web-1 running"],
            "a job that has ended is not waited for, only looked at")

        // Once everything is stopped, a new start begins with the job again.
        try await run.project().stop()
        run.engine.clearCalls()
        try await run.project().up(try run.plan(Self.migration))
        #expect(run.engine.calls == ["start shop-migrate-1", "start shop-web-1"])

        // The same goes for a start from the labels alone.
        run.engine.clearCalls()
        try await run.project().start()
        #expect(run.engine.calls.isEmpty)
        try await run.project().stop()
        run.engine.clearCalls()
        try await run.project().start()
        #expect(run.engine.calls == ["start shop-migrate-1", "start shop-web-1"])
    }

    @Test
    func aJobThatWasMadeAgainRunsEvenWhileItsDependentsRun() async throws {
        let run = ComposeRun()
        run.engine.exits["shop-migrate-1"] = 0
        try await run.project().up(try run.plan(Self.migration))
        // The job's container is made again by a change, so it has not run yet.
        run.engine.clearCalls()
        try await run.project().up(try run.plan(Self.migration.replacingOccurrences(of: "command: migrate", with: "command: migrate --all")))
        #expect(run.engine.calls == ["remove shop-migrate-1", "create shop-migrate-1", "start shop-migrate-1"])
    }

    @Test
    func aContainerWhoseImageHasChangedIsMadeAgain() async throws {
        let run = ComposeRun()
        let plan = try run.plan("services:\n  web:\n    image: web:1\n  other:\n    image: other:1\n")
        try await run.project().up(plan)
        run.engine.clearCalls()
        // The name now means another image: someone fetched or built it since.
        run.engine.digests["web:1"] = "sha256:newer"
        try await run.project().up(plan)
        #expect(run.engine.calls == ["stop shop-web-1", "remove shop-web-1", "create shop-web-1", "start shop-web-1"])
    }

    @Test
    func aOneShotThatFailsStopsTheRun() async throws {
        let run = ComposeRun()
        run.engine.exits["shop-migrate-1"] = 2
        let message = await failure { try await run.project().up(try run.plan(Self.migration)) }
        #expect(message == "service migrate did not finish successfully: its container shop-migrate-1 ended with exit code 2")
        #expect(!run.engine.calls.contains("start shop-web-1"))
    }

    @Test
    func aDependencyThatIsNotRequiredDoesNotStopTheRun() async throws {
        let run = ComposeRun()
        run.engine.exits["shop-migrate-1"] = 2
        let optional = Self.migration.replacingOccurrences(
            of: "condition: service_completed_successfully", with: "condition: service_completed_successfully\n        required: false")
        try await run.project().up(try run.plan(optional))
        #expect(run.engine.calls.last == "start shop-web-1")
        #expect(run.recorder.warnings.count == 1)
        #expect(run.recorder.warnings.first?.hasPrefix("web starts without migrate, which it does not require") == true)
    }

    @Test
    func waitHoldsUntilEveryCheckPasses() async throws {
        let run = ComposeRun()
        run.engine.probes["shop-web-1"] = [1, 0]
        var options = ComposeProject.UpOptions()
        options.wait = true
        try await run.project().up(
            try run.plan("services:\n  web:\n    image: web:1\n    healthcheck:\n      test: curl -f localhost\n  other:\n    image: other:1\n"),
            options: options)
        #expect(run.engine.calls.suffix(2) == ["probe shop-web-1", "probe shop-web-1"])
        #expect(run.recorder.events.last == "container shop-web-1 healthy")
    }

    @Test
    func externalNetworksAndVolumesHaveToExist() async throws {
        let yaml = """
            services:
              web:
                image: web:1
                networks: [shared]
                volumes:
                  - theirs:/data
            networks:
              shared:
                external: true
                name: proxy
            volumes:
              theirs:
                external: true
            """
        let run = ComposeRun()
        #expect(
            await failure { try await run.project().up(try run.plan(yaml)) }
                == "the network proxy is declared external and does not exist; create it with: container network create proxy")
        run.engine.addNetwork("proxy")
        #expect(
            await failure { try await run.project().up(try run.plan(yaml)) }
                == "the volume shop_theirs is declared external and does not exist; create it with: container volume create shop_theirs")
        run.engine.addVolume("shop_theirs")
        try await run.project().up(try run.plan(yaml))
        #expect(run.engine.calls == ["create shop-web-1", "start shop-web-1"], "what is someone else's is used, not made")
    }

    @Test
    func aContainerThatIsSomeoneElsesIsNotTakenOver() async throws {
        let run = ComposeRun()
        run.engine.add(ComposeContainer(id: "shop-web-1", image: "nginx", state: .running, labels: [:]))
        let message = await failure { try await run.project().up(try run.plan("services:\n  web:\n    image: web:1\n")) }
        #expect(message.hasPrefix("a container named shop-web-1 exists and is not this project's web service"))
        #expect(!run.engine.calls.contains { $0.hasPrefix("remove") || $0.hasPrefix("stop") })
    }

    @Test
    func containersTheFileNoLongerAccountsForAreNamedOrRemoved() async throws {
        let run = ComposeRun()
        try await run.project().up(try run.plan("services:\n  web:\n    image: web:1\n  old:\n    image: old:1\n"))
        run.engine.clearCalls()

        let without = try run.plan("services:\n  web:\n    image: web:1\n")
        try await run.project().up(without)
        #expect(run.engine.calls.isEmpty)
        #expect(
            run.recorder.warnings == [
                "the project has containers that no service in the compose file accounts for: shop-old-1. Remove them with --remove-orphans"
            ])

        var options = ComposeProject.UpOptions()
        options.removeOrphans = true
        try await run.project().up(without, options: options)
        #expect(run.engine.calls == ["stop shop-old-1", "remove shop-old-1"])
    }

    @Test
    func aServiceInAnInactiveProfileIsNotAnOrphan() async throws {
        let run = ComposeRun()
        let yaml = "services:\n  web:\n    image: web:1\n  tools:\n    image: tools:1\n    profiles: [debug]\n"
        try await run.project().up(try run.plan(yaml, services: ["tools", "web"]))
        try await run.project().up(try run.plan(yaml))
        #expect(run.recorder.warnings.isEmpty)
    }

    @Test
    func aServiceThatHasToBeBuiltNeedsABuilder() async throws {
        let yaml = "services:\n  api:\n    build: ./api\n  worker:\n    build: ./api\n    image: shop-api\n  web:\n    image: web:1\n"
        let cannot = ComposeRun()
        let message = await failure { try await cannot.project().up(try cannot.plan(yaml)) }
        #expect(message.hasPrefix("the image of service api has to be built first. Build it with: container build --tag shop-api "))
        #expect(!cannot.engine.calls.contains { $0.hasPrefix("create") })

        let can = ComposeRun()
        try await can.project(building: true).up(try can.plan(yaml))
        #expect(can.recorder.builds == ["api: shop-api"], "two services with one build have it built once")
        #expect(can.recorder.events.prefix(4).suffix(2) == ["image shop-api building", "image shop-api built"])

        // An image that is there is not built again, unless asked.
        let again = ComposeRun()
        again.engine.addImage("shop-api")
        try await again.project(building: true).up(try again.plan(yaml))
        #expect(again.recorder.builds.isEmpty)
        var options = ComposeProject.UpOptions()
        options.build = true
        try await again.project(building: true).up(try again.plan(yaml), options: options)
        #expect(again.recorder.builds == ["api: shop-api"])
    }

    @Test
    func pullAlwaysFetchesFirstAndRemakesWhatChanged() async throws {
        let run = ComposeRun()
        let yaml = "services:\n  web:\n    image: web:latest\n    pull_policy: always\n  other:\n    image: other:1\n"
        run.engine.digests["web:latest"] = "sha256:first"
        try await run.project().up(try run.plan(yaml))
        #expect(run.engine.calls.first { $0.hasPrefix("pull") } == "pull web:latest")
        #expect(!run.engine.arguments(of: "shop-web-1").contains("--pull"), "the create does not fetch what was fetched a moment ago")
        run.engine.clearCalls()

        try await run.project().up(try run.plan(yaml))
        #expect(run.engine.calls == ["pull web:latest"], "the same image is not a reason to make the container again")
        run.engine.clearCalls()

        run.engine.digests["web:latest"] = "sha256:second"
        try await run.project().up(try run.plan(yaml))
        #expect(run.engine.calls == ["pull web:latest", "stop shop-web-1", "remove shop-web-1", "create shop-web-1", "start shop-web-1"])

        // --pull on the command line is every service's policy for this run.
        run.engine.clearCalls()
        var options = ComposeProject.UpOptions()
        options.pull = .never
        options.forceRecreate = true
        try await run.project().up(try run.plan(yaml), options: options)
        #expect(!run.engine.calls.contains { $0.hasPrefix("pull") })
        #expect(run.engine.arguments(of: "shop-other-1").suffix(3).prefix(2) == ["--pull", "never"])
    }

    @Test
    func aPortWithNoHostPortGetsAFreeOne() async throws {
        let run = ComposeRun()
        try await run.project().up(try run.plan("services:\n  web:\n    image: web:1\n    ports:\n      - \"80\"\n      - \"127.0.0.1::53/udp\"\n"))
        let arguments = run.engine.arguments(of: "shop-web-1")
        #expect(arguments.contains("49152:80"))
        #expect(arguments.contains("127.0.0.1:49153:53/udp"))
        #expect(arguments.last == "web:1")
    }

    @Test
    func aFolderThatIsNotThereIsMade() async throws {
        let run = ComposeRun()
        let made = Recorder()
        var project = run.project()
        project.pathExists = { !$0.hasSuffix("/data") }
        project.makeDirectory = { path in made.hooks().warning(path) }
        let plan = try run.plan("services:\n  web:\n    image: web:1\n    volumes:\n      - ./data:/data\n      - ./conf:/conf\n")
        try await project.up(plan)
        #expect(made.warnings.count == 1)
        #expect(made.warnings.first?.hasSuffix("/shop/data") == true)

        var refusing = ComposeRun().project()
        refusing.pathExists = { _ in false }
        refusing.makeDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }
        let message = await failure { try await refusing.up(plan) }
        #expect(message.contains("/shop/data, which service web mounts, does not exist and could not be made"))
    }

    @Test
    func aStartThatFailsIsReportedAndStopsTheRun() async throws {
        let run = ComposeRun()
        run.engine.failingStarts = ["shop-db-1"]
        let message = await failure { try await run.project().up(try run.plan(Self.chain)) }
        #expect(message == "the engine could not start shop-db-1")
        #expect(run.recorder.events.last == "container shop-db-1 failed (the engine could not start shop-db-1)")
        #expect(!run.engine.calls.contains("start shop-api-1"))
    }
}

struct LifecycleTests {
    private static let stack = """
        services:
          web:
            image: web:1
            stop_grace_period: 30s
            depends_on:
              db:
                condition: service_healthy
          db:
            image: postgres:16
            healthcheck:
              test: pg_isready
            volumes:
              - data:/var/lib/postgresql/data
          worker:
            image: worker:1
            depends_on: [db]
        volumes:
          data:
        """

    private func running() async throws -> ComposeRun {
        let run = ComposeRun()
        try await run.project().up(try run.plan(Self.stack))
        run.engine.clearCalls()
        return run
    }

    @Test
    func downTakesTheProjectApartInReverseAndLeavesTheData() async throws {
        let run = try await running()
        run.engine.addNetwork("someone-elses")
        run.engine.add(ComposeContainer(id: "bystander", image: "nginx", state: .running, labels: [:]))
        try await run.project().down()
        #expect(
            run.engine.calls == [
                "stop shop-worker-1", "stop shop-web-1 in 30s", "stop shop-db-1",
                "remove shop-worker-1", "remove shop-web-1", "remove shop-db-1",
                "network remove shop_default",
            ])
        #expect(run.engine.containerNames == ["bystander"])
        #expect(run.engine.networkNames == ["someone-elses"])
        #expect(run.engine.volumeNames == ["shop_data"], "a volume holds data, and stays")

        try await run.project().up(try run.plan(Self.stack))
        run.engine.clearCalls()
        try await run.project().down(removeVolumes: true, timeout: 1)
        #expect(run.engine.calls.contains("stop shop-web-1 in 1s"), "a timeout on the command line is the one used")
        #expect(run.engine.calls.last == "volume remove shop_data")
        #expect(run.engine.volumeNames.isEmpty)
    }

    @Test
    func downOnNothingDoesNothing() async throws {
        let run = ComposeRun()
        try await run.project().down(removeVolumes: true)
        #expect(run.engine.calls.isEmpty)
    }

    @Test
    func stopAndStartGoByTheLabelsWithoutTheFile() async throws {
        let run = try await running()
        try await run.project().stop()
        #expect(run.engine.calls == ["stop shop-worker-1", "stop shop-web-1 in 30s", "stop shop-db-1"])
        run.engine.clearCalls()

        try await run.project().start()
        #expect(run.engine.calls == ["start shop-db-1", "probe shop-db-1", "start shop-web-1", "start shop-worker-1"])
        #expect(run.recorder.events.contains("container shop-db-1 healthy"))
        run.engine.clearCalls()

        try await run.project().start()
        #expect(run.engine.calls == ["probe shop-db-1"], "what runs is left running")
    }

    @Test
    func aNamedServiceIsStoppedAndStartedAlone() async throws {
        let run = try await running()
        try await run.project().stop(services: ["web"])
        #expect(run.engine.calls == ["stop shop-web-1 in 30s"])
        run.engine.clearCalls()
        try await run.project().start(services: ["web"])
        #expect(run.engine.calls == ["start shop-web-1"], "a dependency that was not named is not waited for")
        run.engine.clearCalls()
        try await run.project().restart(services: ["worker", "db"], timeout: 2)
        #expect(run.engine.calls == ["stop shop-worker-1 in 2s", "stop shop-db-1 in 2s", "start shop-db-1", "start shop-worker-1"])

        do {
            try await run.project().stop(services: ["ghost"])
            Issue.record("expected an error")
        } catch {
            #expect("\(error)" == "the project shop has no container for a service named 'ghost'")
        }
    }

    @Test
    func aStopWaitsAsLongAsTheServiceSaysThenAsTheCallerPrefers() async throws {
        let run = try await running()
        var project = run.project()
        project.defaultStopTimeout = 12
        try await project.stop()
        #expect(
            run.engine.calls == ["stop shop-worker-1 in 12s", "stop shop-web-1 in 30s", "stop shop-db-1 in 12s"],
            "a service's own grace period comes before the caller's default")
        try await project.start()
        run.engine.clearCalls()
        try await project.stop(timeout: 1)
        #expect(run.engine.calls == ["stop shop-worker-1 in 1s", "stop shop-web-1 in 1s", "stop shop-db-1 in 1s"], "and a timeout given with the stop comes before both")
    }

    @Test
    func aCancelledRunStopsBeforeTheNextContainer() async throws {
        let run = ComposeRun()
        let plan = try run.plan(Self.stack)
        let project = run.project()
        let task = Task {
            // Cancelled before it begins: nothing is made at all.
            withUnsafeCurrentTask { $0?.cancel() }
            try await project.up(plan)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(run.engine.calls.isEmpty)
    }

    @Test
    func aRunCancelledPartWayLeavesWhatItMadeAndBeginsNothingMore() async throws {
        let run = ComposeRun()
        let plan = try run.plan(Self.stack)
        // The first container's creation is where the caller gives up.
        let recorder = Recorder()
        var hooks = recorder.hooks()
        hooks.event = { event in
            if event.status == .created, event.subject == .container { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let project = ComposeProject(name: "shop", engine: run.engine, hooks: hooks)
        await #expect(throws: CancellationError.self) { try await Task { try await project.up(plan) }.value }
        #expect(run.engine.calls.filter { $0.hasPrefix("create") } == ["create shop-db-1"], "the container being made is finished")
        #expect(!run.engine.calls.contains { $0.hasPrefix("start") })
    }

    @Test
    func theProjectsContainersAreListedByService() async throws {
        let run = try await running()
        let containers = try await run.project().containers()
        #expect(containers.map(\.id) == ["shop-db-1", "shop-web-1", "shop-worker-1"])
        #expect(containers.map(\.service) == ["db", "web", "worker"])
        #expect(containers[1].dependencies == [ComposeDependency(service: "db", condition: .healthy)])
        #expect(containers[0].healthcheck?.test == ["/bin/sh", "-c", "pg_isready"])
        #expect(containers[1].stopTimeout == 30)
        #expect(try await ComposeRun().project().containers().isEmpty)
    }

    @Test
    func pullAndBuildWorkOnThePlan() async throws {
        let yaml = "services:\n  api:\n    build: .\n  web:\n    image: web:1\n  twin:\n    image: web:1\n"
        let run = ComposeRun()
        try await run.project(building: true).pull(try run.plan(yaml))
        #expect(run.engine.calls == ["pull web:1"])
        try await run.project(building: true).build(try run.plan(yaml))
        #expect(run.recorder.builds == ["api: shop-api"])
    }
}

struct ReadinessTests {
    @Test(arguments: [(0.5, "0.5 seconds"), (1.0, "1 second"), (15.0, "15 seconds"), (2.04, "2 seconds"), (90.26, "90.3 seconds")])
    func secondsReadNaturally(_ interval: Double, _ text: String) {
        #expect(Readiness.seconds(interval) == text)
    }

    @Test
    func theStartPeriodIsExtraTime() async throws {
        let run = ComposeRun()
        run.engine.add(ComposeContainer(id: "db", image: "postgres", state: .running, labels: [:]))
        run.engine.probes["db"] = [1]
        let clock = run.clock
        let readiness = Readiness(now: { clock.now }, sleep: { clock.advance($0) }, pollInterval: 1)
        let check = ComposeHealthcheck(test: ["true"], interval: 2, timeout: 1, retries: 2, startPeriod: 10)
        do {
            try await readiness.waitUntilHealthy(check, service: "db", container: "db", engine: run.engine)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".hasPrefix("service db is not healthy after 14 seconds"))
        }
    }

    @Test
    func aContainerThatIsGoneCannotBeWaitedFor() async throws {
        let run = ComposeRun()
        let readiness = Readiness(now: { 0 }, sleep: { _ in }, pollInterval: 1)
        do {
            _ = try await readiness.waitUntilExited(service: "job", container: "job", engine: run.engine)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)" == "service job cannot be waited for: its container job is gone")
        }
    }
}
