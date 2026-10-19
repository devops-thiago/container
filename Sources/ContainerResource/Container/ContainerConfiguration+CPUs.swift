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
import Virtualization

extension ContainerConfiguration.Resources {
    /// The most virtual CPUs Virtualization lets any VM have.
    public static var maximumVirtualCPUs: Int {
        VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }

    /// `count` brought into the range a VM can have, 0 to `virtualCPUs`.
    public static func clampedCPUCount(_ count: Int, virtualCPUs: Int = maximumVirtualCPUs) -> Int {
        min(max(count, 0), virtualCPUs)
    }

    /// These resources with CPU counts no VM can have brought into range, for a configuration
    /// saved before create refused them. The VM is the one such a count always gave, since the
    /// runtime gives a VM at most the host's CPUs, and nothing it computes from them overflows.
    public func clampedCPUs(virtualCPUs: Int = Self.maximumVirtualCPUs) -> Self {
        var resources = self
        resources.cpus = Self.clampedCPUCount(cpus, virtualCPUs: virtualCPUs)
        resources.cpuOverhead = Self.clampedCPUCount(cpuOverhead, virtualCPUs: virtualCPUs)
        return resources
    }

    /// Refuses CPU counts no VM can have. Up to Virtualization's limit a count works as it
    /// always has: the runtime gives the VM at most the host's CPUs. Past it the count means
    /// nothing, and far past it the runtime's CPU quota (`cpus * 100_000`) and the VM's CPU
    /// count (`cpus + cpuOverhead`) overflow, which traps.
    public func validateCPUs(virtualCPUs: Int = Self.maximumVirtualCPUs) throws {
        guard (0...virtualCPUs).contains(cpus) else {
            throw ContainerizationError(.invalidArgument, message: "invalid CPU count \(cpus): the range is 0 to \(virtualCPUs)")
        }
        guard (0...virtualCPUs).contains(cpuOverhead) else {
            throw ContainerizationError(.invalidArgument, message: "invalid CPU overhead \(cpuOverhead): the range is 0 to \(virtualCPUs)")
        }
    }
}
