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

@testable import ContainerResource

/// The VM around a container's memory limit: the limit stays the container's `memory.max`,
/// and the VM adds a reserve sized so the guest outside the container's cgroup keeps working
/// when the container reaches its limit.
struct GuestMemoryReserveTests {
    private static let mib: UInt64 = 1024 * 1024

    @Test("a 1 GiB container gets a 320 MiB reserve, a 1344 MiB VM")
    func oneGiB() {
        #expect(GuestMemoryReserve.bytes(forLimit: 1024 * Self.mib) == 320 * Self.mib)
        #expect(GuestMemoryReserve.vmBytes(forLimit: 1024 * Self.mib) == 1344 * Self.mib)
    }

    /// What the kernel kept from `MemTotal`, measured on VMs of 1152 to 8736 MiB, as a
    /// conservative model: 51 to 55 MiB below 2 GiB (5% here), 139 to 269 MiB from 2 GiB up
    /// (95 MiB plus 2% here).
    private static func kernelKeepsMiB(vmMiB: UInt64) -> UInt64 {
        vmMiB < 2048 ? (vmMiB * 5 + 99) / 100 : 95 + (vmMiB * 2 + 99) / 100
    }

    @Test(
        "the guest keeps at least 200 MiB outside the container's cgroup: the 166 MiB it uses there at the limit, and room above the watermarks",
        arguments: [UInt64(200), 512, 1024, 2048, 4096, 8192, 16384, 65536])
    func leavesRoomOutsideTheCgroup(limitMiB: UInt64) {
        let reserve = GuestMemoryReserve.bytes(forLimit: limitMiB * Self.mib)
        let vmMiB = GuestMemoryReserve.vmBytes(forLimit: limitMiB * Self.mib) / Self.mib
        #expect(vmMiB == limitMiB + reserve / Self.mib)
        #expect(reserve % Self.mib == 0)
        // Signed: a reserve too small must fail here, not trap.
        let memTotalMiB = Int64(vmMiB) - Int64(Self.kernelKeepsMiB(vmMiB: vmMiB))
        #expect(memTotalMiB - Int64(limitMiB) >= 200)
    }

    @Test(
        "the sizes measured live: the model is conservative, and MemTotal left at least 200 MiB outside the limit",
        arguments: [
            // (limit MiB, MemTotal in kB as the guest reported it with this reserve, kernel 6.18.35)
            (UInt64(1024), UInt64(1_319_844)),
            (2048, 2_315_384),
            (4096, 4_432_880),
            (8192, 8_669_916),
        ])
    func measuredSizes(limitMiB: UInt64, memTotalKB: UInt64) {
        let memTotalMiB = Int64(memTotalKB / 1024)
        let vmMiB = GuestMemoryReserve.vmBytes(forLimit: limitMiB * Self.mib) / Self.mib
        #expect(memTotalMiB - Int64(limitMiB) >= 200)
        // The kernel kept no more than the model says, so the model's room is the least there is.
        #expect(Int64(vmMiB) - memTotalMiB <= Int64(Self.kernelKeepsMiB(vmMiB: vmMiB)))
    }

    @Test(
        "the 128 MiB this replaced left less outside the cgroup than the guest uses there",
        arguments: [
            // (limit MiB, MemTotal in kB the guest reported with a 128 MiB reserve)
            (UInt64(1024), UInt64(1_127_716))
        ])
    func oldReserveWasTooSmall(limitMiB: UInt64, memTotalKB: UInt64) {
        #expect(Int64(memTotalKB / 1024) - Int64(limitMiB) < 166)
    }

    @Test("a limit that is not whole MiB still gets a reserve of whole MiB")
    func roundsUp() {
        let limit = 1024 * Self.mib + 4096
        let reserve = GuestMemoryReserve.bytes(forLimit: limit)
        #expect(reserve % Self.mib == 0)
        #expect(reserve == 321 * Self.mib)
    }

    @Test(
        "no limit gives a VM size the VMMs' rounding overflows on",
        arguments: [
            UInt64.max, UInt64.max - 1, UInt64.max - 255 * 1024 * 1024, UInt64(Int64.max), UInt64(Int64.max) + 1, 1 << 62, (1 << 62) + 1,
            UInt64.max / 33 * 32, 1024 * 1024 * 1024 + 1,
        ] as [UInt64])
    func neverOverflowsTheRounding(limit: UInt64) {
        let vm = GuestMemoryReserve.vmBytes(forLimit: limit)
        // Containerization's Virtualization rounding, `(memoryInBytes + mib - 1) & ~(mib - 1)`.
        #expect(!vm.addingReportingOverflow(Self.mib - 1).overflow)
        #expect(vm % Self.mib == 0)
        // Its Cloud Hypervisor rounding, to 2 MiB.
        #expect(!vm.addingReportingOverflow(2 * Self.mib - 1).overflow)
        // Its cgroup limit, `Int64(memoryInBytes)`.
        #expect(vm <= UInt64(Int64.max))
        #expect(vm >= min(limit, GuestMemoryReserve.ceilingBytes))
    }

    @Test(
        "the largest limit is the last whose VM fits",
        arguments: [8 << 30, 32 << 30, 33 << 30, 64 << 30, 192 << 30, 1 << 40, UInt64.max] as [UInt64])
    func largestLimit(vm: UInt64) {
        let largest = GuestMemoryReserve.largestLimit(forVMBytes: vm)
        #expect(largest % Self.mib == 0)
        #expect(GuestMemoryReserve.vmBytes(forLimit: largest) <= vm)
        #expect(GuestMemoryReserve.vmBytes(forLimit: largest + Self.mib) > vm || largest + Self.mib > GuestMemoryReserve.ceilingBytes)
        #expect(GuestMemoryReserve.vmBytes(forLimit: largest + 1) > vm || largest + Self.mib > GuestMemoryReserve.ceilingBytes)
    }

    @Test("a 32 GiB VM holds a container of up to 31,495 MiB")
    func largestLimitFor32GiB() {
        // 31_495 + 288 + ceil(31_495 / 32) = 31_495 + 288 + 985 = 32_768 MiB; one more MiB is 32_769.
        #expect(GuestMemoryReserve.largestLimit(forVMBytes: 32 << 30) == 31_495 * Self.mib)
        #expect(GuestMemoryReserve.vmBytes(forLimit: 31_496 * Self.mib) == 32_769 * Self.mib)
    }

    @Test("a VM too small for the reserve holds no container")
    func largestLimitBelowTheReserve() {
        #expect(GuestMemoryReserve.largestLimit(forVMBytes: 200 * Self.mib) == 0)
    }
}
