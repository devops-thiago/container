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
    /// What vminitd's cgroup `memory.high` holds now.
    func memoryHigh() async throws -> String
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
/// and 2 GB 32 to 47 s against 7 to 8 s (#640). Docker writes a `docker cp` from its daemon, which
/// has no limit of its own, so the copy's page cache counts against the machine, not the
/// container. With the limit lifted the copy's page cache counts against the VM in the same way:
/// the kernel's global dirty limits bound what is not yet written, and the rest is page cache
/// the kernel reclaims under pressure like any other. Every copy into the container lifts it,
/// a copy the Docker API held for a container that had not started yet too.
///
/// The limit goes back to what it was before the lift once the last copy has ended and
/// `settleDelay` has passed, after a sync: by then the kernel has written the copy back, so
/// putting the limit back only drops clean page cache and never leaves vminitd over its limit
/// with dirty pages, where the kernel would make it wait. A sync that takes longer than
/// `syncLimit` leaves the limit lifted and tries again after another `settleDelay`, so a copy
/// that arrives meanwhile is never kept waiting behind it for long. The sync is not started
/// again while the one before is still running: the next try waits for that one, so a guest
/// that never ends a sync holds one agent connection, not one more every `settleDelay`.
actor CopyMemoryHeadroom {
    /// vminitd's cgroup, created by vminitd at boot.
    static let memoryHighPath = "/sys/fs/cgroup/vminitd/memory.high"
    /// What vminitd sets at boot (containerization 0.47.0 `AgentCommand.bootstrap`), put back
    /// when the value before the lift could not be read.
    static let vminitdMemoryHigh: UInt64 = 80 * 1024 * 1024
    static let lifted = "max"
    /// The kernel writes back dirty pages within `dirty_expire_centisecs` (30 s) of their
    /// first write, checked every `dirty_writeback_centisecs` (5 s).
    static let defaultSettleDelay: Duration = .seconds(35)
    static let defaultSyncLimit: Duration = .seconds(10)

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let settleDelay: Duration
    private let syncLimit: Duration
    private let sleep: Sleep
    private let log: Logger?
    private var active = 0
    /// The value to put back, while the limit is lifted.
    private var saved: String?
    /// The wait before putting the limit back, while no copy runs.
    private var restoreTimer: Task<Void, Never>?
    /// Putting the limit back, once started.
    private var restoring: Task<Void, Never>?
    /// The guest's sync, from its start until it ends, which can be after the restore that
    /// started it stopped waiting for it.
    private var syncing: (id: UUID, copiesEndedBefore: Int, task: Task<Void, Never>)?
    /// The restores waiting for `syncing` to end, each until it ends or that restore's time
    /// limit passes.
    private var syncWaiters: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]
    /// How many copies have ended: a sync that began before the last of them may not have
    /// written that copy back.
    private var copiesEnded = 0

    enum SyncEvent: Sendable {
        case ended(Result<Void, any Error>)
        case timedOut
    }

    init(
        settleDelay: Duration = defaultSettleDelay, syncLimit: Duration = defaultSyncLimit,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, log: Logger? = nil
    ) {
        self.settleDelay = settleDelay
        self.syncLimit = syncLimit
        self.sleep = sleep
        self.log = log
    }

    /// Whether the limit is lifted now.
    var lifted: Bool { saved != nil }

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
            copiesEnded += 1
            if active == 0 { scheduleRestore(control) }
        }
        await lift(control)
        return try await operation()
    }

    private func lift(_ control: some VminitdMemoryControl) async {
        while let restoring {
            await restoring.value
        }
        guard saved == nil else { return }
        var before: String
        do {
            before = try await control.memoryHigh().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log?.warning("could not read vminitd's memory limit; it goes back to vminitd's default", metadata: ["error": "\(error)"])
            before = ""
        }
        if before.isEmpty || before == Self.lifted {
            before = String(Self.vminitdMemoryHigh)
        }
        // Another copy may have lifted it while this one read.
        guard saved == nil else { return }
        do {
            try await control.setMemoryHigh(Self.lifted)
            saved = before
            log?.info("lifted vminitd's memory limit for a copy", metadata: ["memory.high": "\(before)"])
        } catch {
            log?.warning("could not lift vminitd's memory limit for a copy", metadata: ["error": "\(error)"])
        }
    }

    private func scheduleRestore(_ control: some VminitdMemoryControl) {
        guard saved != nil, restoreTimer == nil else { return }
        let delay = settleDelay
        let sleep = self.sleep
        restoreTimer = Task {
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.restore(control)
        }
    }

    /// Forget the lifted limit without putting it back: the VM is going away, and a sync still
    /// running ends with it.
    func discard() {
        restoreTimer?.cancel()
        restoreTimer = nil
        saved = nil
        // The next VM's restore starts a sync of its own, never waiting on this VM's.
        syncing?.task.cancel()
        syncing = nil
    }

    /// Whether a sync the guest was asked for has not ended yet.
    var syncRunning: Bool { syncing != nil }

    /// Whether a restore waits for its settle delay.
    var restoreScheduled: Bool { restoreTimer != nil }

    /// Put the limit back unless a copy started meanwhile.
    private func restore(_ control: some VminitdMemoryControl) async {
        restoreTimer = nil
        guard active == 0, let value = saved, restoring == nil else { return }
        let step = Task {
            do {
                guard try await self.synced(control) else {
                    self.log?.warning("the sync before putting vminitd's memory limit back is slow; trying again later")
                    return
                }
                // A copy that started during the sync waits for this step and finds the limit
                // still lifted.
                guard self.active == 0, self.saved != nil else { return }
                try await control.setMemoryHigh(value)
                self.saved = nil
                self.log?.info("put vminitd's memory limit back after a copy", metadata: ["memory.high": "\(value)"])
            } catch {
                self.log?.warning("could not put vminitd's memory limit back after a copy", metadata: ["error": "\(error)"])
            }
        }
        restoring = step
        await step.value
        restoring = nil
        // A sync that ran out of time leaves the limit lifted: try again later.
        if active == 0, saved != nil {
            scheduleRestore(control)
        }
    }

    /// Whether the guest's pages are written back: a sync that began after the last copy
    /// ended within `syncLimit`. A sync is started only when none is running; while one an
    /// earlier try gave up on is still running, this waits for it instead. One that ends in
    /// time but began before the last copy ended counts as not done, and the next try starts
    /// a sync of its own.
    private func synced(_ control: some VminitdMemoryControl) async throws -> Bool {
        let (events, continuation) = AsyncStream<SyncEvent>.makeStream()
        let waiter = UUID()
        syncWaiters[waiter] = continuation
        defer {
            syncWaiters[waiter] = nil
            continuation.finish()
        }
        if syncing == nil {
            let id = UUID()
            syncing = (
                id, copiesEnded,
                Task {
                    do {
                        try await control.sync()
                        await self.syncEnded(id, .success(()))
                    } catch {
                        await self.syncEnded(id, .failure(error))
                    }
                }
            )
        }
        guard let copiesEndedBefore = syncing?.copiesEndedBefore else { return false }
        let limit = syncLimit
        let sleep = self.sleep
        let timer = Task {
            do {
                try await sleep(limit)
                continuation.yield(.timedOut)
            } catch {}
        }
        defer { timer.cancel() }
        for await event in events {
            switch event {
            case .timedOut:
                return false
            case .ended(let result):
                try result.get()
                return copiesEndedBefore == copiesEnded
            }
        }
        return false
    }

    private func syncEnded(_ id: UUID, _ result: Result<Void, any Error>) {
        guard syncing?.id == id else { return }
        syncing = nil
        for waiter in syncWaiters.values {
            waiter.yield(.ended(result))
        }
    }
}

/// `VminitdMemoryControl` over the container's VM.
struct VminitdMemory: VminitdMemoryControl {
    let container: LinuxContainer

    /// Read through the agent's own copy out, the one way vminitd 0.47.0 has to read a file in
    /// the VM: a cgroup file is a regular file, read to its end.
    func memoryHigh() async throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "vminitd-memory-high-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try await RunningCopy.withAgent(of: container) { vminitd, vm in
            try await VminitdCopyAgent(agent: vminitd, vm: vm).copyOut(root: "/", path: CopyMemoryHeadroom.memoryHighPath, to: file)
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

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
