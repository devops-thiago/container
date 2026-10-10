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
import ContainerizationExtras
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

private func attachment(_ network: String, _ hostname: String, _ address: String, aliases: [String] = []) throws -> ContainerResource.Attachment {
    try ContainerResource.Attachment(
        network: network, hostname: hostname, ipv4Address: CIDRv4("\(address)/24"),
        ipv4Gateway: IPv4Address("192.0.2.1"), ipv6Address: nil, macAddress: nil, aliases: aliases)
}

private func snapshot(_ id: String, _ status: RuntimeStatus, _ networks: [ContainerResource.Attachment] = [], restartCount: Int = 0) -> ContainerSnapshot {
    let configuration = ContainerConfiguration(
        id: id,
        image: .init(
            reference: "fixture:latest",
            descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
        process: .init(executable: "/bin/true", arguments: [], environment: []))
    return ContainerSnapshot(configuration: configuration, status: status, networks: networks, restartCount: restartCount)
}

private func member(_ id: String, _ attachments: ContainerResource.Attachment...) -> PeerHosts.Member {
    PeerHosts.Member(id: id, attachments: attachments)
}

/// When the running containers' hosts files are rewritten, decided on snapshots alone.
struct PeerHostsWhenTests {
    @Test("a container that starts running has its networks told")
    func startRefreshesItsNetworks() throws {
        let running = snapshot("b", .running, [try attachment("front", "b", "192.0.2.11"), try attachment("back", "b", "198.51.100.11")])
        #expect(PeerHosts.networksToRefresh(old: snapshot("b", .stopped), new: running) == ["front", "back"])
    }

    @Test("a container that stops, exits, or waits to restart has the networks it ran on told")
    func stopRefreshesTheNetworksItRanOn() throws {
        let running = snapshot("b", .running, [try attachment("front", "b", "192.0.2.11")])
        #expect(PeerHosts.networksToRefresh(old: running, new: snapshot("b", .stopped)) == ["front"])
        // The exit handler clears the networks and marks it restarting: no address answers.
        #expect(PeerHosts.networksToRefresh(old: running, new: snapshot("b", .restarting)) == ["front"])
        // And the restart, once it runs again, tells them again.
        #expect(PeerHosts.networksToRefresh(old: snapshot("b", .restarting), new: running) == ["front"])
    }

    @Test("deleting a running container tells its networks; deleting a stopped one tells nobody")
    func deleteRefreshesOnlyWhatRan() throws {
        let running = snapshot("b", .running, [try attachment("front", "b", "192.0.2.11")])
        #expect(PeerHosts.networksToRefresh(old: running, new: nil) == ["front"])
        #expect(PeerHosts.networksToRefresh(old: snapshot("b", .stopped), new: nil).isEmpty)
    }

    @Test("a create, a bootstrap, and bookkeeping on a running container tell nobody")
    func nothingThatLeavesTheListingAloneRefreshes() throws {
        #expect(PeerHosts.networksToRefresh(old: nil, new: snapshot("b", .stopped)).isEmpty)
        #expect(PeerHosts.networksToRefresh(old: snapshot("b", .stopped), new: snapshot("b", .stopped)).isEmpty)
        let networks = [try attachment("front", "b", "192.0.2.11", aliases: ["web"])]
        #expect(
            PeerHosts.networksToRefresh(
                old: snapshot("b", .running, networks), new: snapshot("b", .running, networks, restartCount: 2)
            ).isEmpty)
        // A container running on no network is nobody's peer.
        #expect(PeerHosts.networksToRefresh(old: snapshot("b", .running), new: snapshot("b", .stopped)).isEmpty)
    }

    @Test("only a running container is anybody's peer")
    func onlyRunningContainersAreMembers() throws {
        let networks = [try attachment("front", "b", "192.0.2.11")]
        #expect(PeerHosts.member(of: snapshot("b", .running, networks)) != nil)
        for status in [RuntimeStatus.stopped, .stopping, .restarting, .unknown] {
            #expect(PeerHosts.member(of: snapshot("b", status, networks)) == nil)
        }
    }
}

/// Whose hosts files are rewritten, and what they list.
struct PeerHostsPlanTests {
    @Test("every running container on a changed network is rewritten, the one that started too, and nobody else")
    func everyRunningContainerOnTheNetwork() throws {
        let members = [
            member("c", try attachment("other", "c", "203.0.113.12")),
            member("b", try attachment("front", "b", "192.0.2.11")),
            member("a", try attachment("front", "a", "192.0.2.10")),
        ]
        let plan = PeerHosts.plan(changed: ["front"], members: members)
        #expect(plan.map(\.id) == ["a", "b"])
        #expect(plan.first { $0.id == "a" }?.peers.map(\.hostname) == ["b"])
        #expect(plan.first { $0.id == "b" }?.peers.map(\.hostname) == ["a"])
        #expect(PeerHosts.plan(changed: [], members: members).isEmpty)
    }

    @Test("a container's peers come network by network in its own order, each network's by hostname")
    func peersInBootOrder() throws {
        let target = member("t", try attachment("back", "t", "198.51.100.10"), try attachment("front", "t", "192.0.2.10"))
        let members = [
            target,
            member("z", try attachment("front", "zeta", "192.0.2.30")),
            member("m", try attachment("front", "mu", "192.0.2.20")),
            member("y", try attachment("back", "upsilon", "198.51.100.30")),
            member("b", try attachment("back", "beta", "198.51.100.20")),
        ]
        let peers = PeerHosts.peers(of: target, among: members)
        #expect(peers.map(\.hostname) == ["beta", "upsilon", "mu", "zeta"])
        #expect(peers.map(\.network) == ["back", "back", "front", "front"])
    }

    @Test("two peers sharing an alias are listed in name order, so the first by name answers")
    func sharedAliasGoesToTheFirstByName() throws {
        let target = member("t", try attachment("front", "t", "192.0.2.10"))
        let members = [
            target,
            member("web-2", try attachment("front", "shop-web-2", "192.0.2.22", aliases: ["web"])),
            member("web-1", try attachment("front", "shop-web-1", "192.0.2.21", aliases: ["web"])),
        ]
        let peers = PeerHosts.peers(of: target, among: members)
        #expect(peers.map(\.hostname) == ["shop-web-1", "shop-web-2"])
        #expect(peers.first { $0.aliases.contains("web") }?.ipv4Address.address.description == "192.0.2.21")
    }

    @Test("a peer on two shared networks is listed once per network, at that network's address; one on neither is not")
    func twoNetworks() throws {
        let target = member("t", try attachment("front", "t", "192.0.2.10"), try attachment("back", "t", "198.51.100.10"))
        let members = [
            target,
            member("p", try attachment("front", "p", "192.0.2.20"), try attachment("back", "p", "198.51.100.20")),
            member("x", try attachment("elsewhere", "x", "203.0.113.20")),
        ]
        let peers = PeerHosts.peers(of: target, among: members)
        #expect(peers.map(\.ipv4Address.address.description) == ["192.0.2.20", "198.51.100.20"])
        #expect(PeerHosts.plan(changed: ["back"], members: members).map(\.id) == ["p", "t"])
    }

    @Test("a peer under the container's own hostname is not listed, as at boot")
    func ownHostnameIsNotAPeer() throws {
        let target = member("t", try attachment("front", "app", "192.0.2.10"))
        let members = [target, member("u", try attachment("front", "app", "192.0.2.10")), member("v", try attachment("front", "v", "192.0.2.11"))]
        #expect(PeerHosts.peers(of: target, among: members).map(\.hostname) == ["v"])
    }
}

/// Writing the planned files: off the operation's path, failures logged, the latest table last.
struct PeerHostsRefresherTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) { lock.withLock { entries.append(entry) } }
        var values: [String] { lock.withLock { entries } }
    }

    private struct CapturingLogHandler: LogHandler {
        var logLevel: Logger.Level = .trace
        var metadata: Logger.Metadata = [:]
        let capture: Capture

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            let id = event.metadata?["id"].map { "\($0)" } ?? ""
            let error = event.metadata?["error"].map { "\($0)" } ?? ""
            capture.append("\(event.level) \(event.message) id=\(id) error=\(error)")
        }
    }

    /// The containers a pass reads, and the files it wrote.
    private actor Fleet {
        var members: [PeerHosts.Member]
        private(set) var reads = 0
        private(set) var writes: [(id: String, peers: [String])] = []

        init(_ members: [PeerHosts.Member]) { self.members = members }

        func read() -> [PeerHosts.Member] {
            reads += 1
            return members
        }

        func set(_ members: [PeerHosts.Member]) { self.members = members }

        /// Returns how many writes there have been, this one included.
        func record(_ rewrite: PeerHosts.Rewrite) -> Int {
            writes.append((rewrite.id, rewrite.peers.map(\.hostname)))
            return writes.count
        }
    }

    /// Holds a write until the test lets it go, and tells the test it is being held.
    private actor Gate {
        private var held = false
        private var heldWaiter: CheckedContinuation<Void, Never>?
        private var opened = false
        private var openWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            held = true
            heldWaiter?.resume()
            heldWaiter = nil
            guard !opened else { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiter = $0 }
        }

        func open() {
            opened = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    private struct GuestUnreachable: Error {}

    @Test("a guest that cannot take its file is logged, and the others are still written")
    func failureIsLoggedAndContained() async throws {
        let capture = Capture()
        let fleet = Fleet([
            member("a", try attachment("front", "a", "192.0.2.10")),
            member("b", try attachment("front", "b", "192.0.2.11")),
            member("c", try attachment("front", "c", "192.0.2.12")),
        ])
        let refresher = PeerHostsRefresher(
            log: Logger(label: "PeerHostsRefresherTests", factory: { _ in CapturingLogHandler(capture: capture) }),
            members: { await fleet.read() },
            apply: { rewrite in
                _ = await fleet.record(rewrite)
                if rewrite.id == "b" { throw GuestUnreachable() }
            })

        await refresher.request(networks: ["front"])
        await refresher.settle()

        #expect(await fleet.writes.map(\.id).sorted() == ["a", "b", "c"])
        let warnings = capture.values.filter { $0.hasPrefix("warning ") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("id=b ") == true)
        #expect(warnings.first?.contains("error=GuestUnreachable") == true)
    }

    @Test("what is asked during a pass is served by one more pass, which reads the containers afresh")
    func requestsDuringAPassCoalesceIntoOneFreshPass() async throws {
        let a = member("a", try attachment("front", "a", "192.0.2.10"))
        let b = member("b", try attachment("front", "b", "192.0.2.11"))
        let c = member("c", try attachment("front", "c", "192.0.2.12"))
        let fleet = Fleet([a, b])
        let gate = Gate()
        let refresher = PeerHostsRefresher(
            log: Logger(label: "PeerHostsRefresherTests", factory: { _ in SwiftLogNoOpLogHandler() }),
            members: { await fleet.read() },
            apply: { rewrite in
                if await fleet.record(rewrite) == 1 {
                    await gate.hold()
                }
            })

        await refresher.request(networks: ["front"])
        await gate.waitUntilHeld()
        // c starts, then something else changes, while the first pass is still writing.
        await fleet.set([a, b, c])
        await refresher.request(networks: ["front"])
        await refresher.request(networks: ["front"])
        await gate.open()
        await refresher.settle()

        #expect(await fleet.reads == 2)
        let writes = await fleet.writes
        #expect(writes.count == 5)
        let last = Dictionary(writes.suffix(3).map { ($0.id, $0.peers) }, uniquingKeysWith: { $1 })
        #expect(last == ["a": ["b", "c"], "b": ["a", "c"], "c": ["a", "b"]])
    }

    @Test("with nothing asked, settling returns at once and nothing is read")
    func nothingAskedNothingDone() async {
        let fleet = Fleet([])
        let refresher = PeerHostsRefresher(
            log: Logger(label: "PeerHostsRefresherTests", factory: { _ in SwiftLogNoOpLogHandler() }),
            members: { await fleet.read() },
            apply: { _ in })
        await refresher.settle()
        await refresher.request(networks: [])
        await refresher.settle()
        #expect(await fleet.reads == 0)
    }
}
