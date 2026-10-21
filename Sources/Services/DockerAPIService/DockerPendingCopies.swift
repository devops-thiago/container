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

/// Archives uploaded into a container that is not running, held until it next starts.
///
/// dockerd writes an upload straight into a stopped container's filesystem. Here a container's
/// filesystem is reachable only while its VM is up, so an upload into a created or exited
/// container is unpacked and checked when it arrives, kept on disk in a `PendingCopyQueue`,
/// and copied in when the container next starts: after its bootstrap and before its init
/// process runs, so the process sees the files as if they had always been there.
/// Testcontainers' `withCopyToContainer` relies on that, as does `docker cp` into a created
/// container. Without a queue, an upload into a container that is not running is refused.
///
/// Every start that takes a container's queue is stamped with a tick of this store's clock. An
/// upload checked against the tick read before its container's state was is refused once a
/// start has taken the queue since, or while one is under way, and its route copies it in
/// itself: it is never held for a start that has already looked.
public actor DockerPendingCopies {
    /// Where uploads are held; nil holds none.
    public nonisolated let queue: PendingCopyQueue?
    /// Ticks once for every start that takes a queue.
    private var clock: UInt64 = 0
    /// When each container's queue was last taken, by engine ID.
    private var taken: [String: UInt64] = [:]
    /// Containers whose start has taken their queue and has not finished.
    private var starting: Set<String> = []
    /// Containers whose queue is being copied in now.
    private var applying: Set<String> = []

    /// A store that holds nothing.
    public init() {
        queue = nil
    }

    /// A store over `queue`. What a service before it left half written is removed.
    public init(queue: PendingCopyQueue) {
        self.queue = queue
        queue.sweepStaging()
    }

    /// A directory for an upload that is to be held, to unpack into
    /// (`PendingCopyQueue.root(of:)`) before it is added.
    nonisolated func stage() throws -> URL {
        guard let queue else { throw DockerAPIError.internalError("uploads into a container that is not running are not held") }
        do {
            return try queue.stage()
        } catch {
            throw DockerAPIError.internalError("could not make a directory for the copy: \(error)")
        }
    }

    /// The clock now, to check an upload against once it is unpacked.
    func now() -> UInt64 {
        clock
    }

    /// Holds the staged `upload` for `engineID`'s next start, unless a start has taken its
    /// queue since the clock read `observed`, or is taking it now. Returns whether it is held:
    /// one that is not is the caller's to copy in, and its directory the caller's to remove.
    func add(_ upload: URL, record: PendingCopyQueue.Record, engineID: String, observed: UInt64) throws -> Bool {
        guard let queue, taken[engineID, default: 0] <= observed, !starting.contains(engineID) else { return false }
        do {
            _ = try queue.commit(upload, record: record, container: engineID)
        } catch {
            throw DockerAPIError.internalError("\(error)")
        }
        return true
    }

    /// Whether anything waits to be copied into `engineID`.
    public func holds(_ engineID: String) -> Bool {
        queue?.holds(engineID) ?? false
    }

    /// Copies what waits for `engineID` into it, in the order it was uploaded, with `copyIn`,
    /// dropping each entry once it is in. The first upload that cannot be read, or entry that
    /// cannot be copied in, stops it, and the error names it: that and everything after it
    /// stay held for the next start.
    ///
    /// - Parameter starting: a start is taking the queue, and holds it until `finishedStart`;
    ///   false for a container already running, started where this service did not see it.
    func apply(
        _ engineID: String, starting: Bool,
        copyIn: @escaping @Sendable (_ source: URL, _ destination: String, _ mode: UInt32, _ requester: String?) async throws -> Void
    ) async throws {
        // Before anything awaits: an upload unpacked from here on is not held for this start.
        clock += 1
        taken[engineID] = clock
        if starting { self.starting.insert(engineID) }
        guard let queue, applying.insert(engineID).inserted else { return }
        defer { applying.remove(engineID) }
        do {
            try queue.claim(engineID)
            try await queue.apply(engineID) { source, destination, mode, requester in
                do {
                    try await copyIn(source, destination, mode, requester)
                } catch {
                    throw Reason(message: DockerContainerProcesses.message(error))
                }
            }
            queue.release(engineID)
        } catch let failure as PendingCopyQueue.Failure {
            throw DockerAPIError.internalError(failure.message)
        }
    }

    /// An error's words, as a copy's failure names them.
    struct Reason: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The start that took `engineID`'s queue is over, started or not.
    func finishedStart(_ engineID: String) {
        starting.remove(engineID)
    }

    /// Drops what waits for a container that is gone.
    func discard(_ engineID: String) {
        taken[engineID] = nil
        queue?.drop(engineID)
    }

    /// The containers anything waits for.
    func heldContainers() -> [String] {
        queue?.containersHolding() ?? []
    }
}
