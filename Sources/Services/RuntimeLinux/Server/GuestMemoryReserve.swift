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
/// Measured on a 1152 MiB VM (1 GiB limit plus the 128 MiB this replaced), kernel 6.18:
/// - `MemTotal` was 1101 MiB: 51 MiB never reaches the guest's allocator, 18 MiB of it the
///   page structs (64 bytes per 4 KiB page, 1/64 of the VM).
/// - With the container held at its limit, 166 MiB was in use outside its cgroup (vminitd's
///   cgroup at its 80 MiB `memory.high`, 17 MiB of unreclaimable slab, the rest page cache
///   of vminitd and the root cgroup).
/// - `min_free_kbytes` was 4238 (high watermark 6.3 MiB).
///
/// So the old 128 MiB left the guest 77 MiB outside the container where it needs about 166,
/// and the container could never reach its limit without starving the rest of the guest.
/// With 256 MiB (a 896 MiB limit on the same VM) the guest kept 39 MiB free at the cap,
/// execs answered within 2 s through the container's thrashing, no atomic allocation failed,
/// and the cgroup OOM killer ended the workload.
public enum GuestMemoryReserve {
    /// The fixed part: the measured 166 MiB used outside the container's cgroup at its cap,
    /// the kernel's own 33 MiB beyond the page structs, and about 40 MiB kept free for
    /// atomic allocations above the watermarks.
    public static let fixedBytes: UInt64 = 240 * mib

    /// The page structs: one 64-byte `struct page` per 4 KiB page of the VM.
    public static let pageStructDivisor: UInt64 = 64

    /// The reserve for a container limited to `limitBytes`, rounded up to whole MiB.
    public static func bytes(forLimit limitBytes: UInt64) -> UInt64 {
        let scaled = limitBytes / pageStructDivisor
        let (total, overflow) = fixedBytes.addingReportingOverflow(scaled)
        guard !overflow else { return UInt64.max }
        return roundUpToMiB(total)
    }

    /// The VM memory for a container limited to `limitBytes`: the limit plus the reserve,
    /// saturating rather than trapping on a limit no VM could have.
    public static func vmBytes(forLimit limitBytes: UInt64) -> UInt64 {
        let (total, overflow) = limitBytes.addingReportingOverflow(bytes(forLimit: limitBytes))
        return overflow ? UInt64.max : total
    }

    private static let mib: UInt64 = 1024 * 1024

    private static func roundUpToMiB(_ value: UInt64) -> UInt64 {
        let remainder = value % mib
        guard remainder != 0 else { return value }
        let (rounded, overflow) = value.addingReportingOverflow(mib - remainder)
        return overflow ? UInt64.max : rounded
    }
}
