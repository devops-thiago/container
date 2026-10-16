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

/// Archives uploaded into a container that is not running, held until it next starts.
///
/// dockerd writes an upload straight into a stopped container's filesystem. Here a container's
/// filesystem is reachable only while its VM is up, so an upload into a created or exited
/// container is unpacked and checked when it arrives, kept in the scratch directory, and copied
/// in when the container next starts: after its bootstrap and before its init process runs, so
/// the process sees the files as if they had always been there. Testcontainers'
/// `withCopyToContainer` relies on that, as does `docker cp` into a created container.
///
/// What is held lives as long as this service: an agent that restarts in between loses it.
public actor DockerPendingCopies {
    /// One upload: what it unpacked to and where it goes.
    struct Upload: Sendable {
        /// The upload's own scratch directory, removed once it is copied in or dropped.
        let scratch: URL
        /// Where the archive was unpacked, inside `scratch`.
        let root: URL
        let entries: [DockerExtractedEntry]
        /// The directory in the container the entries go into.
        let destination: String
        let requester: String?
    }

    private var uploads: [String: [Upload]] = [:]

    public init() {}

    func add(_ upload: Upload, engineID: String) {
        uploads[engineID, default: []].append(upload)
    }

    /// Whether anything waits to be copied into `engineID`.
    public func holds(_ engineID: String) -> Bool {
        !(uploads[engineID] ?? []).isEmpty
    }

    /// Copies what waits for `engineID` into it, in the order it was uploaded, with `copyIn`,
    /// then removes it. Everything is removed whether or not the copy succeeds: what failed
    /// to copy fails the start, and a start that is tried again begins without it.
    func apply(
        _ engineID: String,
        copyIn: (_ source: URL, _ destination: String, _ mode: UInt32, _ requester: String?) async throws -> Void
    ) async throws {
        guard let pending = uploads.removeValue(forKey: engineID), !pending.isEmpty else { return }
        defer {
            for upload in pending { try? FileManager.default.removeItem(at: upload.scratch) }
        }
        for upload in pending {
            for entry in upload.entries {
                do {
                    try await copyIn(upload.root.appending(path: entry.name), upload.destination, entry.mode, upload.requester)
                } catch {
                    throw DockerAPIError.internalError(
                        "could not copy \(entry.name) into \(upload.destination) before the start: \(DockerContainerProcesses.message(error))")
                }
            }
        }
    }

    /// Drops what waits for a container that is gone.
    func discard(_ engineID: String) {
        for upload in uploads.removeValue(forKey: engineID) ?? [] {
            try? FileManager.default.removeItem(at: upload.scratch)
        }
    }

    /// Drops everything, for a service that is stopping.
    func shutdown() {
        for upload in uploads.values.joined() {
            try? FileManager.default.removeItem(at: upload.scratch)
        }
        uploads = [:]
    }
}
