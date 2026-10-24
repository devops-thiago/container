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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerResource

// Shared fixture (reused by later tasks' tests). If an initializer is rejected,
// correct it against Sources/ContainerResource/Image/ImageDescription.swift and
// Sources/ContainerResource/Container/ProcessConfiguration.swift.
func makeTestConfiguration(
    id: String = "test-ctr",
    labels: [String: String] = [:],
    creationDate: Date? = nil
) -> ContainerConfiguration {
    let image = ImageDescription(
        reference: "docker.io/library/alpine:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:" + String(repeating: "0", count: 64),
            size: 0
        )
    )
    let process = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0),
        supplementalGroups: [],
        rlimits: []
    )
    var config = ContainerConfiguration(id: id, image: image, process: process)
    config.labels = labels
    if let creationDate { config.creationDate = creationDate }
    return config
}

struct ContainerConfigurationHostnameTests {
    @Test func roundTripsHostname() throws {
        var config = makeTestConfiguration()
        config.hostname = "web"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.hostname == "web")
    }

    @Test func roundTripsExtraHosts() throws {
        var config = makeTestConfiguration()
        config.extraHosts = [.init(name: "host.docker.internal", address: "host-gateway"), .init(name: "db", address: "10.0.0.5")]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.extraHosts == config.extraHosts)
    }

    @Test func bundlesWithoutExtraHostsDecodeAsNone() throws {
        let data = try JSONEncoder().encode(makeTestConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "extraHosts")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.extraHosts.isEmpty)
    }

    @Test func roundTripsRestartPolicyInDockerSpelling() throws {
        for policy in [ContainerConfiguration.RestartPolicy.no, .always, .unlessStopped, .onFailure(maxRetries: nil), .onFailure(maxRetries: 3)] {
            var config = makeTestConfiguration()
            config.restartPolicy = policy
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
            #expect(decoded.restartPolicy == policy)
        }
        var config = makeTestConfiguration()
        config.restartPolicy = .onFailure(maxRetries: 3)
        let object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(config)) as? [String: Any])
        let encoded = try #require(object["restartPolicy"] as? [String: Any])
        #expect(encoded["name"] as? String == "on-failure")
        #expect(encoded["maxRetries"] as? Int == 3)
    }

    @Test func bundlesWithoutARestartPolicyDecodeAsNone() throws {
        let data = try JSONEncoder().encode(makeTestConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "restartPolicy")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.restartPolicy == nil)
    }

    @Test func bundlesWithoutAHostnameDecodeAsNone() throws {
        let data = try JSONEncoder().encode(makeTestConfiguration())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "hostname")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.hostname == nil)
    }
}

struct ContainerConfigurationResourcesTests {
    @Test func roundTripsCpuOverhead() throws {
        var config = makeTestConfiguration()
        config.resources.cpuOverhead = 2
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.resources.cpuOverhead == 2)
    }

    @Test func decodesMissingCpuOverheadAsDefault() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var resources = try #require(obj["resources"] as? [String: Any])
        resources.removeValue(forKey: "cpuOverhead")
        obj["resources"] = resources
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.resources.cpuOverhead == 1)
    }
}

struct ContainerConfigurationCreationDateTests {
    @Test func roundTripsCreationDate() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let config = makeTestConfiguration(creationDate: when)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.creationDate == when)
    }

    @Test func decodesMissingCreationDateAsEpoch() throws {
        let config = makeTestConfiguration(creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "creationDate")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.creationDate == Date(timeIntervalSince1970: 0))
    }
}

struct ContainerCPUBoundTests {
    @Test("CPU counts up to Virtualization's limit are kept, with or without the VM's own CPU")
    func keepsCountsAVMCanHave() throws {
        var resources = ContainerConfiguration.Resources()
        for cpus in [0, 1, 4, 63, 64] {
            resources.cpus = cpus
            try resources.validateCPUs(virtualCPUs: 64)
        }
        // A machine keeps no CPU of its own.
        resources.cpuOverhead = 0
        try resources.validateCPUs(virtualCPUs: 64)
    }

    @Test(
        "CPU counts no VM can have are refused before they overflow the runtime",
        arguments: [65, 100_000_000_000_000, Int.max / 100_000 + 1, Int.max - 1, Int.max, -1, Int.min])
    func refusesCountsNoVMCanHave(cpus: Int) {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = cpus
        #expect(throws: Error.self) { try resources.validateCPUs(virtualCPUs: 64) }
    }

    @Test("an overhead outside the VM's limit is refused, so the sum cannot overflow", arguments: [-1, 65, Int.min, Int.max])
    func refusesOverhead(overhead: Int) {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 1
        resources.cpuOverhead = overhead
        #expect(throws: Error.self) { try resources.validateCPUs(virtualCPUs: 64) }
    }

    @Test("the production limit is Virtualization's")
    func productionLimit() throws {
        #expect(ContainerConfiguration.Resources.maximumVirtualCPUs >= ProcessInfo.processInfo.activeProcessorCount)
        var resources = ContainerConfiguration.Resources()
        resources.cpus = ContainerConfiguration.Resources.maximumVirtualCPUs
        try resources.validateCPUs()
        resources.cpus += 1
        #expect(throws: Error.self) { try resources.validateCPUs() }
    }
}

struct ContainerMemoryBoundTests {
    private static let mib: UInt64 = 1024 * 1024
    private static let vm: UInt64 = 32 << 30

    @Test("limits whose VM fits are kept, up to the largest")
    func keepsLimitsAVMCanHave() throws {
        var resources = ContainerConfiguration.Resources()
        for limit in [200 * Self.mib, 1 << 30, 16 << 30, 31_495 * Self.mib] {
            resources.memoryInBytes = limit
            try resources.validateMemory(virtualMemory: Self.vm)
        }
    }

    @Test(
        "a limit whose VM cannot fit is refused before it overflows the runtime",
        arguments: [(31_495 << 20) + 1, 31_496 << 20, 32 << 30, UInt64(Int64.max), UInt64.max - 1, UInt64.max] as [UInt64])
    func refusesLimitsNoVMCanHave(limit: UInt64) {
        var resources = ContainerConfiguration.Resources()
        resources.memoryInBytes = limit
        let error = #expect(throws: ContainerizationError.self) { try resources.validateMemory(virtualMemory: Self.vm) }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message.contains("the most a container can have is 31495 MiB") == true)
    }

    @Test("a saved limit no VM can have is brought down to the largest, and the rest kept", arguments: [UInt64(64) << 30, UInt64.max])
    func clampsSavedLimits(limit: UInt64) throws {
        var resources = ContainerConfiguration.Resources()
        resources.memoryInBytes = limit
        resources.cpus = 3
        let clamped = resources.clampedMemory(virtualMemory: Self.vm)
        #expect(clamped.memoryInBytes == 31_495 * Self.mib)
        #expect(clamped.cpus == 3)
        try clamped.validateMemory(virtualMemory: Self.vm)
        #expect(GuestMemoryReserve.vmBytes(forLimit: clamped.memoryInBytes) <= Self.vm)
    }

    @Test("the production limit is Virtualization's")
    func productionLimit() throws {
        let maximum = ContainerConfiguration.Resources.maximumMemoryLimit()
        #expect(maximum > 0)
        #expect(GuestMemoryReserve.vmBytes(forLimit: maximum) <= ContainerConfiguration.Resources.maximumVirtualMemory)
        var resources = ContainerConfiguration.Resources()
        resources.memoryInBytes = maximum
        try resources.validateMemory()
        resources.memoryInBytes = maximum + Self.mib
        #expect(throws: ContainerizationError.self) { try resources.validateMemory() }
    }
}

struct ContainerConfigurationWritableSysfsTests {
    /// `config` as an engine from before `writableSysfs` saved it.
    static func savedWithoutTheKey(_ config: ContainerConfiguration) throws -> ContainerConfiguration {
        let data = try JSONEncoder().encode(config)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.removeValue(forKey: "writableSysfs") != nil)
        return try JSONDecoder().decode(ContainerConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func aNewContainerIsReadOnly() {
        #expect(makeTestConfiguration().writableSysfs == false)
    }

    @Test func roundTrips() throws {
        var config = makeTestConfiguration()
        config.writableSysfs = true
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.writableSysfs == true)
    }

    @Test(
        "Legacy labels cannot authorize writable /sys",
        arguments: [
            ([:], false),
            (["com.example.app": "web"], false),
            ([ResourceLabelKeys.role: ResourceRoleValues.builder, ResourceLabelKeys.plugin: "builder"], false),
            ([ResourceLabelKeys.plugin: ResourcePluginValues.kubernetes, ResourceLabelKeys.role: "control-plane"], false),
            ([ResourceLabelKeys.plugin: ResourcePluginValues.machine], false),
            ([ResourceLabelKeys.plugin: "compose"], false),
        ]
    )
    func savedWithoutTheKey(labels: [String: String], writable: Bool) throws {
        let decoded = try Self.savedWithoutTheKey(makeTestConfiguration(labels: labels))
        #expect(decoded.writableSysfs == writable)
    }

    @Test func aSavedValueWinsOverTheLabels() throws {
        var config = makeTestConfiguration(labels: [ResourceLabelKeys.role: ResourceRoleValues.builder])
        config.writableSysfs = false
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.writableSysfs == false)
    }
}
