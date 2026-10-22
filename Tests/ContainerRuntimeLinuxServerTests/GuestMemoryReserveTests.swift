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

@testable import ContainerRuntimeLinuxServer

/// The VM around a container's memory limit: the limit stays the container's `memory.max`,
/// and the VM adds a reserve sized so the guest outside the container's cgroup keeps working
/// when the container reaches its limit.
struct GuestMemoryReserveTests {
    private static let mib: UInt64 = 1024 * 1024

    @Test("a 1 GiB container gets a 256 MiB reserve, a 1280 MiB VM")
    func oneGiB() {
        #expect(GuestMemoryReserve.bytes(forLimit: 1024 * Self.mib) == 256 * Self.mib)
        #expect(GuestMemoryReserve.vmBytes(forLimit: 1024 * Self.mib) == 1280 * Self.mib)
    }

    @Test(
        "the reserve covers what the guest used outside the container at its cap, and grows with the page structs",
        arguments: [UInt64(200), 512, 1024, 2048, 4096, 8192, 16384, 65536])
    func coversMeasuredUse(limitMiB: UInt64) {
        let reserve = GuestMemoryReserve.bytes(forLimit: limitMiB * Self.mib)
        // Measured on a 1152 MiB VM held at its cap: 51 MiB never reached the allocator and
        // 166 MiB was in use outside the container's cgroup. The 128 MiB this replaced left
        // 77 MiB of the 166.
        #expect(reserve >= (51 + 166) * Self.mib)
        // One 64-byte page struct per 4 KiB page of the limit, on top of the fixed part.
        #expect(reserve >= GuestMemoryReserve.fixedBytes + limitMiB * Self.mib / 64)
        #expect(reserve % Self.mib == 0)
        #expect(GuestMemoryReserve.vmBytes(forLimit: limitMiB * Self.mib) == limitMiB * Self.mib + reserve)
    }

    @Test("a limit that is not whole MiB still gets a reserve of whole MiB")
    func roundsUp() {
        let limit = 1024 * Self.mib + 4096
        let reserve = GuestMemoryReserve.bytes(forLimit: limit)
        #expect(reserve % Self.mib == 0)
        #expect(reserve == 257 * Self.mib)
    }

    @Test("a limit no VM could have saturates instead of trapping", arguments: [UInt64.max, UInt64.max - 1, UInt64.max - 255 * 1024 * 1024])
    func saturates(limit: UInt64) {
        #expect(GuestMemoryReserve.vmBytes(forLimit: limit) == UInt64.max)
    }
}
