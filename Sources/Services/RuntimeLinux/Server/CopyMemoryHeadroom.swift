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
import Foundation
import Logging

/// What lifting vminitd's memory limit for a copy asks of the VM's agent.
protocol VminitdMemoryControl: Sendable {
    /// Write `value` to vminitd's cgroup `memory.high`.
    func setMemoryHigh(_ value: String) async throws
    /// Write every dirty page in the VM back to its disk.
    func sync() async throws
}

/// Lifts vminitd's `memory.high` while copies into the container run, and puts it back after.
///
/// vminitd writes the files a copy brings in itself, so their page cache is charged to its own
/// cgroup, whose `memory.high` is 80 MiB (containerization 0.47.0,
/// `vminitd/Sources/VminitdCore/AgentCommand.swift`). Cgroup writeback sizes a cgroup's dirty
/// pages from its limit, so that gave a copy about 16 MiB of dirty pages and made it nearly
/// write-through: 300 MB took 2 to 8 s where the same bytes through `exec -i … cat >` took 1 s,
/// and 2 GB 32 to 47 s against 7 to 8 s (#640). Docker writes a `docker cp` from its daemon, which has no
/// limit of its own, so the copy's page cache counts against the machine, not the container.
/// With the limit lifted the copy's page cache counts against the VM in the same way: the
/// kernel's global dirty limits bound what is not yet written, and the rest is page cache the
/// kernel reclaims under pressure like any other.
///
/// The limit goes back once the last copy has ended and `settleDelay` has passed, after a
/// sync: by then the kernel has written the copy back, so putting the limit back only drops
/// clean page cache and never leaves vminitd over its limit with dirty pages, where the
/// kernel would make it wait.
actor CopyMemoryHeadroom {
    /// vminitd's cgroup, created by vminitd at boot.
    static let memoryHighPath = "/sys/fs/cgroup/vminitd/memory.high"
    /// What vminitd sets at boot (containerization 0.47.0 `AgentCommand.bootstrap`).
    static let vminitdMemoryHigh: UInt64 = 80 * 1024 * 1024
    static let lifted = "max"
    /// The kernel writes back dirty pages within `dirty_expire_centisecs` (30 s) of their
    /// first write, checked every `dirty_writeback_centisecs` (5 s).
    static let defaultSettleDelay: Duration = .seconds(35)

    private let settleDelay: Duration
    private let log: Logger?
    private var active = 0
    private var isLifted = false
    /// The wait before putting the limit back, while no copy runs.
    private var restoreTimer: Task<Void, Never>?
    /// Putting the limit back, once started.
    private var restoring: Task<Void, Never>?

    init(settleDelay: Duration = defaultSettleDelay, log: Logger? = nil) {
        self.settleDelay = settleDelay
        self.log = log
    }

    /// Whether the limit is lifted now.
    var lifted: Bool { isLifted }

    /// Run `operation`, a copy into the container, with vminitd's limit lifted. A failure to
    /// lift it is logged and the copy runs anyway, at the speed it had before.
    func withLifted<T: Sendable>(
        _ control: some VminitdMemoryControl, _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        active += 1
        restoreTimer?.cancel()
        restoreTimer = nil
        defer {
            active -= 1
            if active == 0 { scheduleRestore(control) }
        }
        await lift(control)
        return try await operation()
    }

    private func lift(_ control: some VminitdMemoryControl) async {
        while let restoring {
            await restoring.value
        }
        guard !isLifted else { return }
        do {
            try await control.setMemoryHigh(Self.lifted)
            isLifted = true
            log?.info("lifted vminitd's memory limit for a copy")
        } catch {
            log?.warning("could not lift vminitd's memory limit for a copy", metadata: ["error": "\(error)"])
        }
    }

    private func scheduleRestore(_ control: some VminitdMemoryControl) {
        guard isLifted, restoreTimer == nil else { return }
        let delay = settleDelay
        restoreTimer = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self.restore(control)
        }
    }

    /// Forget the lifted limit without putting it back: the VM is going away.
    func discard() {
        restoreTimer?.cancel()
        restoreTimer = nil
        isLifted = false
    }

    /// Put the limit back unless a copy started meanwhile.
    private func restore(_ control: some VminitdMemoryControl) async {
        restoreTimer = nil
        guard active == 0, isLifted, restoring == nil else { return }
        let step = Task {
            do {
                try await control.sync()
                // A copy that started during the sync waits for this step and finds the limit
                // still lifted.
                guard self.active == 0 else { return }
                try await control.setMemoryHigh(String(Self.vminitdMemoryHigh))
                self.isLifted = false
                self.log?.info("put vminitd's memory limit back after a copy", metadata: ["memory.high": "\(Self.vminitdMemoryHigh)"])
            } catch {
                self.log?.warning("could not put vminitd's memory limit back after a copy", metadata: ["error": "\(error)"])
            }
        }
        restoring = step
        await step.value
        restoring = nil
    }
}

/// `VminitdMemoryControl` over the container's VM.
struct VminitdMemory: VminitdMemoryControl {
    let container: LinuxContainer

    func setMemoryHigh(_ value: String) async throws {
        try await RunningCopy.withAgent(of: container) { vminitd, _ in
            // `Vminitd.writeFile` takes flags whose initializer containerization keeps internal;
            // the request without them opens the file for writing only, as a cgroup file needs.
            let client = Com_Apple_Containerization_Sandbox_V3_SandboxContext.Client(wrapping: vminitd.grpcClient)
            _ = try await client.writeFile(
                .with {
                    $0.path = CopyMemoryHeadroom.memoryHighPath
                    $0.data = Data(value.utf8)
                })
        }
    }

    func sync() async throws {
        try await RunningCopy.withAgent(of: container) { vminitd, _ in
            try await vminitd.sync()
        }
    }
}
