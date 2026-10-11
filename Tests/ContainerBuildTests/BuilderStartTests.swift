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
import Testing

struct BuilderStartTests {
    static let image = "example.com/builder:1"

    static let systemConfig = ContainerSystemConfig(
        build: BuildConfig(cpus: 2, memory: try! MemorySize("2048MB"), image: image)
    )

    /// A spec from default options and an environment with nothing the start manages.
    static func spec(
        _ options: Builder.StartOptions = .init(),
        environment: [String: String] = [:]
    ) throws -> Builder.StartSpec {
        try Builder.StartSpec(options: options, containerSystemConfig: systemConfig, environment: environment)
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

    // MARK: - Start action

    @Test func startActionFollowsStatusAndDifference() throws {
        #expect(try Builder.startAction(status: nil, requiresRecreate: false) == .create)
        #expect(try Builder.startAction(status: .unknown, requiresRecreate: true) == .create)
        #expect(try Builder.startAction(status: .running, requiresRecreate: false) == .reuse)
        #expect(try Builder.startAction(status: .running, requiresRecreate: true) == .stopAndRecreate)
        #expect(try Builder.startAction(status: .stopped, requiresRecreate: false) == .restart)
        #expect(try Builder.startAction(status: .stopped, requiresRecreate: true) == .deleteAndRecreate)
    }

    @Test func aBuilderInTransitionCannotBeStarted() {
        for status in [RuntimeStatus.stopping, .restarting] {
            for recreate in [false, true] {
                #expect(throws: ContainerizationError.self) {
                    try Builder.startAction(status: status, requiresRecreate: recreate)
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
