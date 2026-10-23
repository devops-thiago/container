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

/// The memory a container's VM has beyond the container's own limit.
///
/// The container's processes are capped by its cgroup's `memory.max`, which is the memory
/// the container was given, as with Docker's `--memory`. Everything else in the guest lives
/// outside that cgroup: the kernel's own pages, vminitd (whose cgroup holds about 80 MiB, its
/// `memory.high`), the root cgroup's slab and page cache, the NIC's receive buffers, and the
/// free pages the kernel keeps for atomic allocations. If the VM leaves them less than they
/// use, a container that reaches its limit drives the whole guest into reclaim before its
/// own limit trips: vminitd and the NIC starve, execs hang, and the cgroup's OOM killer never
/// gets to act.
///
/// Measured with kernel 6.18.35:
/// - With a 1 GiB container held at its limit, 166 MiB was in use outside its cgroup
///   (vminitd's cgroup at its 80 MiB `memory.high`, 17 MiB of unreclaimable slab, the rest
///   page cache of vminitd and the root cgroup). `min_free_kbytes` was 4238 to 11654 from a
///   1 GiB to an 8 GiB VM.
/// - The kernel keeps part of the VM from `MemTotal`, and more as the VM grows: 51 MiB of a
///   1152 MiB VM, 53 of 1280, 139 of 2320, 181 of 4400 and 265 of 8560, about 95 MiB plus 2%
///   from 2 GiB up.
/// - The 128 MiB this replaced left 77 MiB outside a 1 GiB container where the guest uses
///   166, so the container never reached its limit without starving the rest of the guest.
///
/// The reserve is 288 MiB plus 1/32 of the limit, which leaves at least 200 MiB outside the
/// container's cgroup at every size measured: the 166 MiB in use and about 40 MiB free above
/// the watermarks for atomic allocations. With it, a 1 GiB container at its limit kept the
/// rest of the guest working (execs answered within 10 s through the container's own
/// thrashing, the NIC never failed an allocation) and the cgroup's OOM killer ended it.
public enum GuestMemoryReserve {
    /// The fixed part: the 166 MiB in use outside the container's cgroup at its limit, about
    /// 40 MiB kept free, and the kernel's fixed share of what it keeps from `MemTotal`.
    public static let fixedBytes: UInt64 = 288 * mib

    /// The part that grows with the VM: the kernel keeps about 2% of it, page structs
    /// included; 1/32 covers that with room to spare.
    public static let scaledDivisor: UInt64 = 32

    /// The reserve for a container limited to `limitBytes`, rounded up to whole MiB.
    public static func bytes(forLimit limitBytes: UInt64) -> UInt64 {
        let scaled = limitBytes / scaledDivisor
        let (total, overflow) = fixedBytes.addingReportingOverflow(scaled)
        guard !overflow else { return UInt64.max }
        return roundUpToMiB(total)
    }

    /// The VM memory for a container limited to `limitBytes`: the limit plus the reserve,
    /// rounded up to whole MiB as Virtualization takes it. A limit no VM could have gives
    /// ``ceilingBytes`` rather than trapping, so the rounding the VMMs apply after it cannot
    /// overflow either; create refuses such a limit (see
    /// `ContainerConfiguration.Resources.validateMemory`) before a VM is ever sized from it.
    public static func vmBytes(forLimit limitBytes: UInt64) -> UInt64 {
        let (total, overflow) = limitBytes.addingReportingOverflow(bytes(forLimit: limitBytes))
        guard !overflow, total <= ceilingBytes else { return ceilingBytes }
        return min(roundUpToMiB(total), ceilingBytes)
    }

    /// Where ``vmBytes(forLimit:)`` saturates: far past any VM Virtualization allows, a
    /// multiple of the 1 MiB Virtualization and the 2 MiB Cloud Hypervisor round to, below
    /// `Int64.max`, and with room above it for either rounding to add.
    public static let ceilingBytes: UInt64 = (1 << 63) - (2 * mib)

    /// The largest limit, in whole MiB, whose VM fits in `vmBytes`; 0 when not even the
    /// reserve does.
    public static func largestLimit(forVMBytes maximum: UInt64) -> UInt64 {
        var low: UInt64 = 0
        var high = min(maximum, ceilingBytes) / mib
        while low < high {
            let middle = high - (high - low) / 2
            if vmBytes(forLimit: middle * mib) <= maximum {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return vmBytes(forLimit: low * mib) <= maximum ? low * mib : 0
    }

    private static let mib: UInt64 = 1024 * 1024

    private static func roundUpToMiB(_ value: UInt64) -> UInt64 {
        let remainder = value % mib
        guard remainder != 0 else { return value }
        let (rounded, overflow) = value.addingReportingOverflow(mib - remainder)
        return overflow ? UInt64.max : rounded
    }
}
