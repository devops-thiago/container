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

import ContainerBuild
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import SystemPackage
import Testing

struct BuilderStartTests {
    static let image = "example.com/builder:1"

    static let systemConfig = ContainerSystemConfig(
        build: BuildConfig(cpus: 2, memory: try! MemorySize("2048MB"), image: image)
    )

    /// A run directory of a plausible length for an app group's container.
    static let runDirectory = URL(fileURLWithPath: "/Users/me/Library/Group Containers/TEAM.dev.example.App/run", isDirectory: true)

    /// A spec from default options and an environment with nothing the start manages.
    static func spec(
        _ options: Builder.StartOptions = .init(),
        environment: [String: String] = [:],
        runDirectory: URL? = nil
    ) throws -> Builder.StartSpec {
        try Builder.StartSpec(options: options, containerSystemConfig: systemConfig, environment: environment, runDirectory: runDirectory)
    }

    /// A run directory whose BuildKit socket path is exactly `bytes` long.
    static func runDirectory(socketPathBytes bytes: Int) -> URL {
        let fixed = "/" + "/\(Builder.buildKitSocketName)"
        return URL(fileURLWithPath: "/" + String(repeating: "r", count: bytes - fixed.utf8.count), isDirectory: true)
    }

    /// The configuration a start from `spec` would have created.
    static func existing(
        matching spec: Builder.StartSpec,
        edit: (inout ContainerConfiguration) -> Void = { _ in }
    ) -> ContainerConfiguration {
        let descriptor = Descriptor(mediaType: MediaTypes.index, digest: "sha256:" + String(repeating: "0", count: 64), size: 0)
        let process = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: [],
            environment: ["PATH=/usr/bin"] + spec.managedEnvironment
        )
        var config = ContainerConfiguration(
            id: Builder.builderContainerId,
            image: ImageDescription(reference: spec.image, descriptor: descriptor),
            process: process
        )
        config.resources = spec.resources
        config.ssh = spec.ssh
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: spec.dnsNameservers,
            domain: spec.dnsDomain,
            searchDomains: spec.dnsSearchDomains,
            options: spec.dnsOptions
        )
        config.publishedSockets = spec.publishedSockets ?? []
        edit(&config)
        return config
    }

    // MARK: - Spec

    @Test func specTakesTheSystemDefaults() throws {
        let spec = try Self.spec()
        #expect(spec.image == Self.image)
        #expect(spec.resources.cpus == 2)
        #expect(spec.resources.memoryInBytes == 2048 * 1024 * 1024)
        #expect(spec.managedEnvironment.isEmpty)
        #expect(spec.ssh == false)
    }

    @Test func specOptionsOverrideTheDefaults() throws {
        let spec = try Self.spec(.init(cpus: 6, memory: "4g"))
        #expect(spec.resources.cpus == 6)
        #expect(spec.resources.memoryInBytes == 4096 * 1024 * 1024)
    }

    @Test func specRejectsAnUnreadableMemorySize() {
        #expect(throws: (any Error).self) { try Self.spec(.init(memory: "lots")) }
    }

    @Test func sshNeedsTheAgentSocket() throws {
        #expect(try Self.spec(.init(ssh: true)).ssh == false)
        #expect(try Self.spec(.init(ssh: true), environment: ["SSH_AUTH_SOCK": "/tmp/agent"]).ssh == true)
        #expect(try Self.spec(.init(ssh: false), environment: ["SSH_AUTH_SOCK": "/tmp/agent"]).ssh == false)
    }

    @Test func managedEnvironmentKeepsOnlyColourSettingsSorted() {
        #expect(Builder.managedEnvironment(["PATH": "/bin", "TERM": "xterm"]).isEmpty)
        #expect(
            Builder.managedEnvironment(["NO_COLOR": "", "BUILDKIT_COLORS": "run=green"])
                == ["BUILDKIT_COLORS=run=green", "NO_COLOR=true"])
        #expect(Builder.managedEnvironment(["NO_COLOR": "1"]) == ["NO_COLOR=true"])
    }

    // MARK: - Recreate decision

    @Test func aMatchingBuilderIsKept() throws {
        let spec = try Self.spec(.init(dnsNameservers: ["9.9.9.9"]), environment: ["NO_COLOR": "1"])
        #expect(spec.requiresRecreate(Self.existing(matching: spec)) == false)
    }

    @Test func unmanagedEnvironmentDoesNotCount() throws {
        let spec = try Self.spec()
        let existing = Self.existing(matching: spec) { $0.initProcess.environment.append("HOME=/root") }
        #expect(spec.requiresRecreate(existing) == false)
    }

    @Test func eachDifferenceRecreates() throws {
        let spec = try Self.spec()
        let edits: [(String, (inout ContainerConfiguration) -> Void)] = [
            ("image", { $0.image = ImageDescription(reference: "example.com/builder:2", descriptor: $0.image.descriptor) }),
            ("cpus", { $0.resources.cpus = 8 }),
            ("memory", { $0.resources.memoryInBytes = 1024 }),
            ("environment", { $0.initProcess.environment.append("NO_COLOR=true") }),
            ("ssh", { $0.ssh = true }),
        ]
        for (name, edit) in edits {
            #expect(spec.requiresRecreate(Self.existing(matching: spec, edit: edit)), "\(name)")
        }
    }

    @Test func aColourSettingThatWentAwayRecreates() throws {
        let colourful = try Self.spec(environment: ["BUILDKIT_COLORS": "run=green"])
        let plain = try Self.spec()
        #expect(plain.requiresRecreate(Self.existing(matching: colourful)))
    }

    @Test func dnsIsComparedOnlyWhenAsked() throws {
        let spec = try Self.spec()
        let existing = Self.existing(matching: spec) {
            $0.dns = .init(nameservers: ["8.8.8.8"], domain: "corp", searchDomains: ["a"], options: ["ndots:2"])
        }
        #expect(spec.requiresRecreate(existing) == false)
    }

    @Test func dnsComparesOnlyTheFirstFieldAsked() throws {
        let existingDNS = ContainerConfiguration.DNSConfiguration(
            nameservers: ["8.8.8.8"], domain: "corp", searchDomains: ["a"], options: ["ndots:2"])
        func recreates(_ options: Builder.StartOptions) throws -> Bool {
            let spec = try Self.spec(options)
            return spec.requiresRecreate(Self.existing(matching: spec) { $0.dns = existingDNS })
        }

        // Nameservers decide when they are given: the other fields are not looked at.
        #expect(try recreates(.init(dnsNameservers: ["8.8.8.8"], dnsDomain: "other")) == false)
        #expect(try recreates(.init(dnsNameservers: ["1.1.1.1"], dnsDomain: "corp")))
        // Then the domain.
        #expect(try recreates(.init(dnsDomain: "corp", dnsSearchDomains: ["b"])) == false)
        #expect(try recreates(.init(dnsDomain: "other")))
        // Then the search domains.
        #expect(try recreates(.init(dnsSearchDomains: ["a"], dnsOptions: ["rotate"])) == false)
        #expect(try recreates(.init(dnsSearchDomains: ["b"])))
        // Then the options.
        #expect(try recreates(.init(dnsOptions: ["ndots:2"])) == false)
        #expect(try recreates(.init(dnsOptions: ["rotate"])))
    }

    @Test func dnsAskedOfABuilderWithoutDNSRecreates() throws {
        let spec = try Self.spec(.init(dnsDomain: "corp"))
        #expect(spec.requiresRecreate(Self.existing(matching: spec) { $0.dns = nil }))
    }

    @Test func eachHardDifferenceRecreatesNow() throws {
        let spec = try Self.spec(runDirectory: Self.runDirectory)
        // With a socket difference too: the hard one decides.
        let existing = Self.existing(matching: spec) {
            $0.resources.cpus = 8
            $0.publishedSockets = []
        }
        #expect(spec.recreate(existing) == .now)
        #expect(spec.recreate(Self.existing(matching: spec)) == .no)
    }

    // MARK: - Published BuildKit socket

    @Test func theBuildKitSocketIsPublishedPrivatelyInTheRunDirectory() throws {
        let sockets = try Builder.publishedSockets(runDirectory: Self.runDirectory)
        #expect(sockets.count == 1)
        let socket = try #require(sockets.first)
        #expect(socket.containerPath == "/run/buildkit/buildkitd.sock")
        #expect(socket.hostPath == FilePath(Self.runDirectory.path(percentEncoded: false)).appending("buildkitd.sock"))
        #expect(socket.permissions == FilePermissions(rawValue: 0o600))
    }

    @Test func aSocketPathBuildxCannotDialIsNotPublished() throws {
        #expect(PathUtils.maxDialableSocketPathBytes == 103)
        let longest = Self.runDirectory(socketPathBytes: 103)
        let published = try Builder.publishedSockets(runDirectory: longest)
        #expect(published.first?.hostPath.string.utf8.count == 103)
        // One byte more and there is nothing to publish.
        #expect(try Builder.publishedSockets(runDirectory: Self.runDirectory(socketPathBytes: 104)).isEmpty)
    }

    @Test func theSpecCarriesTheSocketOnlyWhenTheRunDirectoryIsKnown() throws {
        #expect(try Self.spec().publishedSockets == nil)
        #expect(try Self.spec(runDirectory: Self.runDirectory).publishedSockets == Builder.publishedSockets(runDirectory: Self.runDirectory))
        #expect(try Self.spec(runDirectory: Self.runDirectory(socketPathBytes: 104)).publishedSockets == [])
    }

    @Test func aBuilderWithoutTheSocketIsReplacedWhenStopped() throws {
        let spec = try Self.spec(runDirectory: Self.runDirectory)
        let old = Self.existing(matching: spec) { $0.publishedSockets = [] }
        #expect(spec.recreate(old) == .whenStopped)
        #expect(spec.requiresRecreate(old))
    }

    @Test func aBuilderWithASocketNoLongerWantedIsReplacedWhenStopped() throws {
        let spec = try Self.spec(runDirectory: Self.runDirectory(socketPathBytes: 104))
        let existing = Self.existing(matching: spec) { $0.publishedSockets = try! Builder.publishedSockets(runDirectory: Self.runDirectory) }
        #expect(spec.recreate(existing) == .whenStopped)
    }

    @Test func aSocketThatChangedIsReplacedWhenStopped() throws {
        let spec = try Self.spec(runDirectory: Self.runDirectory)
        let elsewhere = try Builder.publishedSockets(runDirectory: URL(fileURLWithPath: "/Users/me/run", isDirectory: true))
        #expect(spec.recreate(Self.existing(matching: spec) { $0.publishedSockets = elsewhere }) == .whenStopped)
        let open = Self.existing(matching: spec) { $0.publishedSockets[0].permissions = FilePermissions(rawValue: 0o666) }
        #expect(spec.recreate(open) == .whenStopped)
    }

    @Test func theSameSocketIsKept() throws {
        let spec = try Self.spec(runDirectory: Self.runDirectory)
        let existing = Self.existing(matching: spec)
        #expect(existing.publishedSockets.count == 1)
        #expect(spec.recreate(existing) == .no)
    }

    @Test func socketsCompareInAnyOrder() throws {
        let a = try PublishSocket(containerPath: "/run/a.sock", hostPath: "/tmp/a.sock")
        let b = try PublishSocket(containerPath: "/run/b.sock", hostPath: "/tmp/b.sock")
        #expect(Builder.StartSpec.sameSockets([a, b], [b, a]))
        #expect(!Builder.StartSpec.sameSockets([a, b], [a]))
        #expect(!Builder.StartSpec.sameSockets([a, a], [a, b]))
    }

    @Test func anUnknownRunDirectoryLeavesTheSocketsAlone() throws {
        // A caller that cannot find the run directory must not take a builder's socket away.
        let unknown = try Self.spec()
        let withSocket = Self.existing(matching: unknown) { $0.publishedSockets = try! Builder.publishedSockets(runDirectory: Self.runDirectory) }
        #expect(unknown.recreate(withSocket) == .no)
        #expect(unknown.recreate(Self.existing(matching: unknown)) == .no)
    }

    @Test func clientsOfOneEngineAgreeOnTheSocket() throws {
        // The CLI and the Docker API agent take the run directory from the engine's app root,
        // not from their own environments, which differ.
        let appRoot = FilePath("/Users/me/Library/Application Support/com.apple.container")
        let base = FileManager.default.temporaryDirectory.appending(path: "bks-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let engineAppRoot = FilePath(base.appending(path: "engine").path(percentEncoded: false))
        let cli = try Self.spec(environment: ["CONTAINER_APP_ROOT": appRoot.string], runDirectory: PathUtils.runDirectory(engineAppRoot: engineAppRoot))
        let agent = try Self.spec(environment: [:], runDirectory: PathUtils.runDirectory(engineAppRoot: engineAppRoot))
        #expect(cli.publishedSockets == agent.publishedSockets)
        #expect(agent.recreate(Self.existing(matching: cli)) == .no)
    }

    // MARK: - Start action

    @Test func startActionFollowsStatusAndDifference() throws {
        #expect(try Builder.startAction(status: nil, recreate: .no) == .create)
        #expect(try Builder.startAction(status: .unknown, recreate: .now) == .create)
        #expect(try Builder.startAction(status: .running, recreate: .no) == .reuse)
        #expect(try Builder.startAction(status: .running, recreate: .now) == .stopAndRecreate)
        #expect(try Builder.startAction(status: .stopped, recreate: .no) == .restart)
        #expect(try Builder.startAction(status: .stopped, recreate: .now) == .deleteAndRecreate)
    }

    @Test func aRunningBuilderIsNeverStoppedForItsSockets() throws {
        // It may be in the middle of a build nobody told the engine about.
        #expect(try Builder.startAction(status: .running, recreate: .whenStopped) == .reuse)
        // Stopped, it is replaced so the next run publishes.
        #expect(try Builder.startAction(status: .stopped, recreate: .whenStopped) == .deleteAndRecreate)
        #expect(try Builder.startAction(status: nil, recreate: .whenStopped) == .create)
    }

    @Test func aBuilderInTransitionCannotBeStarted() {
        for status in [RuntimeStatus.stopping, .restarting] {
            for recreate in [Builder.Recreate.no, .whenStopped, .now] {
                #expect(throws: ContainerizationError.self) {
                    try Builder.startAction(status: status, recreate: recreate)
                }
            }
        }
    }

    @Test func connectErrorsReadAsTheCLIAlwaysPrintedThem() {
        #expect("\(Builder.ConnectError.timeout)" == "    Timeout waiting for connection to builder")
        #expect("\(Builder.ConnectError.notRunning)" == "builder is not running")
    }

    @Test func resourceDirectoryIsTheBuilderFolder() {
        #expect(Builder.resourceDirectory == "builder")
        #expect(Builder.defaultVsockPort == 8088)
    }
}
