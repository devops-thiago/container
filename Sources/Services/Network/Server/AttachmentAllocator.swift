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
import ContainerizationExtras

actor AttachmentAllocator {
    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: UInt32] = [:]
    /// How many holders each hostname has: the engine, from a container's create to its
    /// delete, and the container's runtime while it runs. The address goes back to the pool
    /// when the last one lets go, so a stopped container keeps the address it had.
    private var holders: [String: Int] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Allocate a network address for a host, or hand another holder the one it has.
    func allocate(hostname: String) async throws -> UInt32 {
        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let index = hostnames[hostname] {
            holders[hostname, default: 0] += 1
            return index
        }

        let index = try allocator.allocate()
        hostnames[hostname] = index
        holders[hostname] = 1

        return index
    }

    /// Let go of a hostname's address. It is freed, and returned, only when no holder is
    /// left; nil while another still has it, or when the hostname was never allocated.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        guard let index = hostnames[hostname] else {
            return nil
        }
        let remaining = (holders[hostname] ?? 1) - 1
        guard remaining <= 0 else {
            holders[hostname] = remaining
            return nil
        }
        holders.removeValue(forKey: hostname)
        hostnames.removeValue(forKey: hostname)

        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[hostname]
    }

    /// Every current allocation, so a joining container can learn its peers' names.
    func allocations() async -> [String: UInt32] {
        hostnames
    }
}
