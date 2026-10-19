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

import ContainerResource
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

struct BootableResourcesTests {
    /// Resources as a configuration saved before create refused large CPU counts holds them.
    private func saved(cpus: Int, overhead: Int = 1) throws -> ContainerConfiguration.Resources {
        let json = #"{"cpus":\#(cpus),"memoryInBytes":1073741824,"cpuOverhead":\#(overhead)}"#
        return try JSONDecoder().decode(ContainerConfiguration.Resources.self, from: Data(json.utf8))
    }

    @Test(
        "a saved CPU count no VM can have boots clamped, without overflowing the VM's count or the quota",
        arguments: [100, 100_000_000_000_000, Int.max - 1, Int.max])
    func clampsSavedCounts(cpus: Int) throws {
        let maximum = ContainerConfiguration.Resources.maximumVirtualCPUs
        let bootable = RuntimeService.bootableResources(try saved(cpus: cpus))
        #expect(bootable.cpus == maximum)
        #expect(bootable.cpuOverhead == 1)
        #expect(!bootable.cpus.addingReportingOverflow(bootable.cpuOverhead).overflow)
        #expect(!bootable.cpus.multipliedReportingOverflow(by: 100_000).overflow)
        // The VM is the one it always was: the runtime gives a VM at most the host's CPUs,
        // and both counts are past them.
        let host = ProcessInfo.processInfo.activeProcessorCount
        #expect(min(bootable.cpus + bootable.cpuOverhead, host) == host)
        try bootable.validateCPUs()
    }

    @Test("a negative count or overhead boots at zero, and the rest is kept")
    func clampsNegatives() throws {
        let bootable = RuntimeService.bootableResources(try saved(cpus: -5, overhead: Int.min))
        #expect(bootable.cpus == 0)
        #expect(bootable.cpuOverhead == 0)
        #expect(bootable.memoryInBytes == 1_073_741_824)
    }

    @Test("every count a VM can have boots unchanged", arguments: [0, 1, 4, 63, 64])
    func keepsValidCounts(cpus: Int) throws {
        let bootable = RuntimeService.bootableResources(try saved(cpus: cpus))
        #expect(bootable.cpus == cpus)
        #expect(bootable.cpuOverhead == 1)
    }
}
