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
import Logging

/// The peer half of a guest's `/etc/hosts`, kept current while the guest runs.
///
/// A guest learns its peers' names only from its hosts file: its resolver can ask port 53
/// alone, which the Mac's own resolver holds, so the engine cannot answer it. The file is
/// seeded at boot with whatever holds an address on the container's networks; from then on
/// the engine rewrites it in every running container on a network whenever a container there
/// starts or stops running, or goes away.
///
/// The table lists running containers only, as Docker's resolver answers for running
/// containers only: a stopped container's name stops resolving, although the engine keeps its
/// address until it is deleted. That hold is so the container comes back on the same address,
/// not so its name keeps answering while nothing is behind it.
enum PeerHosts {
    /// A running container, as its peers' hosts files list it.
    struct Member: Sendable {
        let id: String
        /// One per network, in the container's own network order.
        let attachments: [Attachment]
    }

    /// One container's file to write, and the peers it lists, in file order.
    struct Rewrite: Sendable {
        let id: String
        let peers: [Attachment]
    }

    /// What a container is in its peers' files: nothing unless it runs on some network.
    /// One that is restarting has given its runtime up, and is not running until it starts.
    static func member(of snapshot: ContainerSnapshot) -> Member? {
        guard snapshot.status == .running, !snapshot.networks.isEmpty else { return nil }
        return Member(id: snapshot.id, attachments: snapshot.networks)
    }

    /// The networks whose running containers are told again, when a container goes from `old`
    /// to `new`; nil for a container that does not exist (before a create, after a delete).
    /// Empty when what its peers list did not change: a create, a start of a runtime that has
    /// not started its process, the delete of a stopped container.
    static func networksToRefresh(old: ContainerSnapshot?, new: ContainerSnapshot?) -> Set<String> {
        let before = old.flatMap { member(of: $0) }?.attachments ?? []
        let after = new.flatMap { member(of: $0) }?.attachments ?? []
        guard listing(before) != listing(after) else { return [] }
        return Set(before.map(\.network)).union(after.map(\.network))
    }

    /// The files to write after the running containers on `changed` changed: every running
    /// container on one of those networks, in id order, each with all of its peers, since its
    /// whole file is written. One that is being stopped is still running, still listed, and
    /// still sent its file; its runtime, already going down, leaves it alone.
    static func plan(changed: Set<String>, members: [Member]) -> [Rewrite] {
        members
            .filter { member in member.attachments.contains { changed.contains($0.network) } }
            .sorted { $0.id < $1.id }
            .map { Rewrite(id: $0.id, peers: peers(of: $0, among: members)) }
    }

    /// A container's peers in the order its boot-time file lists them: network by network in
    /// its own network order, each network's by hostname, without anything under its own
    /// hostname there. Two peers sharing an alias both list it, and the first in name order
    /// answers, as at boot.
    static func peers(of target: Member, among members: [Member]) -> [Attachment] {
        target.attachments.flatMap { own in
            members
                .filter { $0.id != target.id }
                .compactMap { member in
                    member.attachments.first { $0.network == own.network }.map { (id: member.id, attachment: $0) }
                }
                .filter { $0.attachment.hostname != own.hostname }
                .sorted { ($0.attachment.hostname, $0.id) < ($1.attachment.hostname, $1.id) }
                .map(\.attachment)
        }
    }

    /// What a peer's file says about these attachments, to tell a change from none.
    private static func listing(_ attachments: [Attachment]) -> [String] {
        attachments.map {
            ([$0.network, $0.hostname, $0.ipv4Address.address.description] + $0.aliases).joined(separator: " ")
        }
    }
}

/// Writes the files `PeerHosts` plans, one pass at a time, off the path of the operation that
/// asked: a failure is logged and the operation that caused it goes on.
///
/// Each pass reads the running containers when it starts, not when it was asked for, so the
/// last pass to run writes the latest table, and the requests that arrive during a pass are
/// served together by the next.
actor PeerHostsRefresher {
    typealias Members = @Sendable () async -> [PeerHosts.Member]
    typealias Apply = @Sendable (PeerHosts.Rewrite) async throws -> Void

    private let log: Logger
    private let members: Members
    private let apply: Apply
    private var pending: Set<String> = []
    private var requested = 0
    private var completed = 0
    private var worker: Task<Void, Never>?
    private var waiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(log: Logger, members: @escaping Members, apply: @escaping Apply) {
        self.log = log
        self.members = members
        self.apply = apply
    }

    /// Have the running containers on `networks` rewritten. Returns at once.
    func request(networks: Set<String>) {
        guard !networks.isEmpty else { return }
        pending.formUnion(networks)
        requested += 1
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    /// Wait for everything asked before this call to be written, or to have failed.
    func settle() async {
        let generation = requested
        guard completed < generation else { return }
        await withCheckedContinuation { waiters.append((generation, $0)) }
    }

    private func drain() async {
        while !pending.isEmpty {
            let networks = pending
            let generation = requested
            pending = []
            await pass(networks)
            completed = generation
            let ready = waiters.filter { $0.generation <= generation }
            waiters.removeAll { $0.generation <= generation }
            for waiter in ready { waiter.continuation.resume() }
        }
        worker = nil
    }

    private func pass(_ networks: Set<String>) async {
        let rewrites = PeerHosts.plan(changed: networks, members: await members())
        guard !rewrites.isEmpty else { return }
        let apply = self.apply
        let log = self.log
        await withTaskGroup(of: Void.self) { group in
            for rewrite in rewrites {
                group.addTask {
                    do {
                        try await apply(rewrite)
                    } catch {
                        log.warning(
                            "could not refresh a running container's hosts file",
                            metadata: [
                                "id": "\(rewrite.id)",
                                "networks": "\(networks.sorted())",
                                "error": "\(error)",
                            ])
                    }
                }
            }
        }
    }
}
