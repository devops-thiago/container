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
    /// The most memory Virtualization lets any VM have.
    public static var maximumVirtualMemory: UInt64 {
        VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    /// The largest memory limit a container can have: its VM is the limit plus the guest's
    /// reserve (``GuestMemoryReserve``), and that VM must fit in `virtualMemory`.
    public static func maximumMemoryLimit(virtualMemory: UInt64 = maximumVirtualMemory) -> UInt64 {
        GuestMemoryReserve.largestLimit(forVMBytes: virtualMemory)
    }

    /// These resources with a memory limit no VM can have brought down to the largest one, for
    /// a configuration saved before create refused it. Such a limit never booted: its VM was
    /// past Virtualization's limit, or far past it overflowed sizing the VM and trapped.
    public func clampedMemory(virtualMemory: UInt64 = Self.maximumVirtualMemory) -> Self {
        var resources = self
        resources.memoryInBytes = min(memoryInBytes, Self.maximumMemoryLimit(virtualMemory: virtualMemory))
        return resources
    }

    /// Refuses a memory limit no VM can have. Docker refuses only a limit below its minimum,
    /// as a Linux cgroup takes any larger one; here the limit sizes the container's VM, which
    /// Virtualization caps, and far past that cap sizing the VM overflows.
    public func validateMemory(virtualMemory: UInt64 = Self.maximumVirtualMemory) throws {
        let maximum = Self.maximumMemoryLimit(virtualMemory: virtualMemory)
        guard memoryInBytes <= maximum else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid memory limit \(memoryInBytes) bytes: the most a container can have is \(maximum >> 20) MiB, "
                    + "as its VM adds a reserve for the guest and Virtualization allows at most \(virtualMemory >> 20) MiB")
        }
    }
}
