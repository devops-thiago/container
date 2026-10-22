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

import Containerization
import Testing

@testable import ContainerRuntimeLinuxServer

/// `/sys` and `/sys/fs/cgroup` as Docker mounts them: read-only unless the container is one
/// Docker would run privileged.
struct SystemMountsTests {
    static func options(_ mounts: [Containerization.Mount], at destination: String) -> [String]? {
        mounts.first { $0.destination == destination }?.options
    }

    @Test func sysAndCgroupAreReadOnlyByDefault() throws {
        let mounts = RuntimeService.systemMounts(LinuxContainer.defaultMounts(), writable: false)
        let sys = try #require(Self.options(mounts, at: "/sys"))
        let cgroup = try #require(Self.options(mounts, at: "/sys/fs/cgroup"))
        #expect(sys == ["nosuid", "noexec", "nodev", "ro"])
        #expect(cgroup == ["nosuid", "noexec", "nodev", "ro"])
    }

    @Test func noOtherMountChanges() {
        let defaults = LinuxContainer.defaultMounts()
        let mounts = RuntimeService.systemMounts(defaults, writable: false)
        #expect(mounts.count == defaults.count)
        for (before, after) in zip(defaults, mounts) where !["/sys", "/sys/fs/cgroup"].contains(before.destination) {
            #expect(after.type == before.type)
            #expect(after.destination == before.destination)
            #expect(after.options == before.options, "\(before.destination)")
        }
    }

    @Test func writableLeavesThemReadWrite() {
        let defaults = LinuxContainer.defaultMounts()
        let mounts = RuntimeService.systemMounts(defaults, writable: true)
        #expect(mounts.map(\.options) == defaults.map(\.options))
        #expect(Self.options(mounts, at: "/sys")?.contains("ro") == false)
        #expect(Self.options(mounts, at: "/sys/fs/cgroup")?.contains("ro") == false)
    }

    @Test func applyingTwiceAddsOneReadOnly() {
        let once = RuntimeService.systemMounts(LinuxContainer.defaultMounts(), writable: false)
        let twice = RuntimeService.systemMounts(once, writable: false)
        #expect(twice.map(\.options) == once.map(\.options))
    }

    @Test func anExplicitReadWriteBecomesReadOnly() {
        let mounts = RuntimeService.systemMounts(
            [.any(type: "sysfs", source: "sysfs", destination: "/sys/", options: ["rw", "nosuid"])], writable: false)
        #expect(mounts.first?.options == ["nosuid", "ro"])
    }

    @Test func aBindOntoSysIsNotTouched() {
        let bind = Containerization.Mount.any(type: "none", source: "/data", destination: "/sys/fs/cgroup", options: ["bind"])
        let mounts = RuntimeService.systemMounts([bind], writable: false)
        #expect(mounts.first?.options == ["bind"])
    }
}
