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
/// container is unpacked and checked when it arrives and held on disk in a `PendingCopyQueue`.
/// The engine copies it in when the container next starts, whoever starts it (this service,
/// the app, `container start`): after its bootstrap and before its init process runs, so the
/// process sees the files as if they had always been there. Testcontainers'
/// `withCopyToContainer` relies on that, as does `docker cp` into a created container. Without
/// a queue, an upload into a container that is not running is refused.
///
/// A start takes the whole queue at once, and holds it taken until its run ends. An upload
/// that finds the queue taken once it is in it takes itself back out and is copied into the
/// container by its route; one the start took first waits for the start to copy it in. It is
/// never held for a start that has already looked.
public struct DockerPendingCopies: Sendable {
    /// What became of an upload handed to `hold`.
    enum Outcome: Sendable {
        /// Held for the container's next start.
        case held
        /// A start had taken the queue: the upload is back in this staged directory, for the
        /// caller to copy into the container and remove.
        case takenBack(URL)
        /// A start took it with the queue and has finished with it: copied in, or, when the
        /// start failed, held again for the next one.
        case takenByStart
    }

    /// Where uploads are held; nil holds none.
    public let queue: PendingCopyQueue?
    /// How long an upload a start took waits for the start to finish with it.
    let startWait: Duration
    /// Runs between an upload's commit and its look at the queue; for tests.
    let afterCommit: (@Sendable () async -> Void)?

    /// A store that holds nothing.
    public init() {
        queue = nil
        startWait = .zero
        afterCommit = nil
    }

    /// A store over `queue`. What a service before it left half written is removed.
    public init(queue: PendingCopyQueue, startWait: Duration = .seconds(600)) {
        self.init(queue: queue, startWait: startWait, afterCommit: nil)
    }

    init(queue: PendingCopyQueue, startWait: Duration, afterCommit: (@Sendable () async -> Void)?) {
        self.queue = queue
        self.startWait = startWait
        self.afterCommit = afterCommit
        queue.sweepStaging()
    }

    /// A directory for an upload that is to be held, to unpack into
    /// (`PendingCopyQueue.root(of:)`) before it is held.
    func stage() throws -> URL {
        guard let queue else { throw DockerAPIError.internalError("uploads into a container that is not running are not held") }
        do {
            return try queue.stage()
        } catch {
            throw DockerAPIError.internalError("could not make a directory for the copy: \(error)")
        }
    }

    /// Puts the staged `upload` in `engineID`'s queue, then makes sure a start has not already
    /// looked at the queue without it.
    func hold(_ upload: URL, record: PendingCopyQueue.Record, engineID: String) async throws -> Outcome {
        guard let queue else { throw DockerAPIError.internalError("uploads into a container that is not running are not held") }
        let name: String
        do {
            name = try queue.commit(upload, record: record, container: engineID)
        } catch {
            throw DockerAPIError.internalError("\(error)")
        }
        await afterCommit?()
        do {
            guard queue.isTaken(engineID) else { return .held }
            if let back = try queue.takeBack(name, container: engineID) { return .takenBack(back) }
        } catch {
            throw DockerAPIError.internalError("\(error)")
        }
        let deadline = ContinuousClock.now.advanced(by: startWait)
        while queue.isApplying(name, container: engineID) {
            guard ContinuousClock.now < deadline else {
                throw DockerAPIError.internalError("the container's start did not finish copying in the upload")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return .takenByStart
    }

    /// Whether anything waits to be copied into `engineID`.
    public func holds(_ engineID: String) -> Bool {
        queue?.holds(engineID) ?? false
    }
}
