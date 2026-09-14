//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing

@testable import ContainerRuntimeLinuxServer

struct SysctlDefaultsTests {
    @Test func noSysctlsGetBothDefaults() {
        let result = RuntimeService.sysctlsWithDefaults([:])
        #expect(result == ["vm.overcommit_memory": "1", "vm.max_map_count": "262144"])
    }

    @Test func unrelatedValuesAreKeptBesideTheDefaults() {
        let result = RuntimeService.sysctlsWithDefaults(["net.ipv4.ip_forward": "1"])
        #expect(result["net.ipv4.ip_forward"] == "1")
        #expect(result["vm.overcommit_memory"] == "1")
        #expect(result["vm.max_map_count"] == "262144")
    }

    @Test func oneExplicitValueSurvivesAndTheOtherKeyIsDefaulted() {
        let result = RuntimeService.sysctlsWithDefaults(["vm.max_map_count": "65530"])
        #expect(result["vm.max_map_count"] == "65530")
        #expect(result["vm.overcommit_memory"] == "1")
    }

    @Test func bothExplicitValuesReachTheGuestUnchanged() {
        let given = ["vm.overcommit_memory": "0", "vm.max_map_count": "1048576", "kernel.pid_max": "4194304"]
        #expect(RuntimeService.sysctlsWithDefaults(given) == given)
    }
}
