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
import Logging
import NIOCore
import SocketForwarder

/// Makes the Mac's loopback services reachable from the network's containers at the gateway,
/// which is where `host.docker.internal` points, as Docker Desktop does.
///
/// macOS gives an unprivileged, sandboxed process no way to take connections for every port of
/// an address (that needs `pf`, and root). So the helper follows the Mac's listeners instead:
/// while a container is on the network it reads the kernel's table of TCP listeners every
/// `interval`, and for each port a service listens on at `127.0.0.1` or `::1` alone it listens
/// on the gateway address (the bridge interface of this network, never a wildcard) and relays
/// each connection to that loopback port. Only clients inside the network's subnet are served,
/// so a machine on the Mac's LAN that routes to the bridge gets nothing.
///
/// Ports below 1024 are left out: macOS lets an unprivileged process bind those only on the
/// wildcard address, never on one interface's.
public actor HostLoopbackForwarder {
    /// One relay the helper keeps: the gateway port and the loopback address it dials.
    public struct Mirror: Sendable, Hashable {
        public let port: UInt16
        public let target: HostListener.Address

        public init(port: UInt16, target: HostListener.Address) {
            self.port = port
            self.target = target
        }
    }

    /// The most ports one network relays, and the most connections it relays at once. The
    /// helper keeps launchd's default limit of 256 descriptors (`launchctl limit maxfiles`):
    /// a relayed port costs one and a relayed connection two, so 64 of each is at most 192,
    /// which leaves the rest for the vmnet, XPC and log descriptors the helper serves every
    /// container of the network with.
    public static let maximumPorts = 64
    public static let maximumConnections = 64

    /// Whether a network gets the relay at all. An `--internal` (host-only) network is meant
    /// to reach nothing but its own containers and the gateway's own services, as Docker's
    /// `network create --internal` is; a relay would hand it every loopback service of the Mac.
    public static func relays(for mode: NetworkMode) -> Bool {
        mode != .hostOnly
    }

    /// The relays the listeners call for: one per port from 1024 up with a loopback listener
    /// and none on every IPv4 address (the gateway already reaches that one), dialling
    /// `127.0.0.1` when a service listens there and `::1` otherwise; the lowest
    /// `maximumPorts` of them.
    public static func plan(_ listeners: [HostListener]) -> Set<Mirror> {
        var reachable: Set<UInt16> = []
        var v4: Set<UInt16> = []
        var v6: Set<UInt16> = []
        for listener in listeners where listener.port >= 1024 {
            switch listener.address {
            case .anyV4: reachable.insert(listener.port)
            case .loopbackV4: v4.insert(listener.port)
            case .loopbackV6: v6.insert(listener.port)
            case .other: break
            }
        }
        let ports = v4.union(v6).subtracting(reachable).sorted().prefix(maximumPorts)
        return Set(ports.map { Mirror(port: $0, target: v4.contains($0) ? .loopbackV4 : .loopbackV6) })
    }

    /// Opens one relay; the result closes it. Injected so tests need no gateway address.
    public typealias Open = @Sendable (Mirror) async throws -> SocketForwarderResult

    private let listeners: @Sendable () throws -> [HostListener]
    private let open: Open
    private let interval: Duration
    private let log: Logger
    private var running: [Mirror: SocketForwarderResult] = [:]
    /// The last failure logged per port, so a port that cannot be had is reported once.
    private var failures: [UInt16: String] = [:]
    /// Whether the listener table could not be read on the last pass, so that is said once.
    private var listenersFailing = false
    private var poller: Task<Void, Never>?
    /// Bumped by `stop`, so a pass that was opening a relay when the last container left
    /// closes it instead of keeping it.
    private var generation = 0

    public init(
        listeners: @escaping @Sendable () throws -> [HostListener],
        open: @escaping Open,
        interval: Duration = .seconds(1),
        log: Logger
    ) {
        self.listeners = listeners
        self.open = open
        self.interval = interval
        self.log = log
    }

    /// The real relays: listen on `gateway`, serve `subnet`, dial the loopback address, at
    /// most `maximumConnections` at a time across the network's ports.
    public init(
        gateway: IPv4Address, subnet: CIDRv4, eventLoopGroup: any EventLoopGroup, log: Logger,
        listeners: @escaping @Sendable () throws -> [HostListener] = HostListeners.current,
        connectionLimit: ConnectionLimit = ConnectionLimit(maximum: HostLoopbackForwarder.maximumConnections)
    ) {
        let open: Open = { mirror in
            let target = mirror.target == .loopbackV6 ? "::1" : "127.0.0.1"
            let forwarder = try TCPForwarder(
                proxyAddress: try SocketAddress(ipAddress: gateway.description, port: Int(mirror.port)),
                serverAddress: try SocketAddress(ipAddress: target, port: Int(mirror.port)),
                eventLoopGroup: eventLoopGroup,
                log: log,
                acceptsPeer: { Self.serves($0, subnet: subnet) },
                connectionLimit: connectionLimit)
            return try await forwarder.run().get()
        }
        self.init(listeners: listeners, open: open, log: log)
    }

    /// Whether a client belongs to the network: an IPv4 address inside its subnet.
    public static func serves(_ peer: SocketAddress, subnet: CIDRv4) -> Bool {
        guard case .v4 = peer, let text = peer.ipAddress, let address = try? IPv4Address(text) else { return false }
        return subnet.contains(address)
    }

    /// The relays kept now.
    public var mirrors: Set<Mirror> { Set(running.keys) }

    /// The ports relayed now.
    public var ports: Set<UInt16> { Set(running.keys.map(\.port)) }

    /// Whether the forwarder is following the listeners now.
    public var isFollowing: Bool { poller != nil }

    /// Follows the listeners while the network has containers (`attached` above zero), and
    /// closes every relay when the last one leaves: with no container there is no bridge to
    /// listen on, and nobody to serve.
    public func attachmentsChanged(_ attached: Int) async {
        if attached > 0 {
            guard poller == nil else { return }
            poller = Task { [weak self] in await self?.follow() }
            log.info("following the host's listeners")
        } else {
            guard let poller else { return }
            self.poller = nil
            poller.cancel()
            await stop()
            log.info("stopped following the host's listeners")
        }
    }

    private func follow() async {
        while !Task.isCancelled {
            await sync()
            try? await Task.sleep(for: interval)
        }
    }

    /// Brings the relays in line with the listeners of the moment, once.
    public func sync() async {
        let pass = generation
        let wanted: Set<Mirror>
        do {
            wanted = Self.plan(try listeners())
            if listenersFailing {
                listenersFailing = false
                log.info("following the host's listeners again")
            }
        } catch {
            if !listenersFailing {
                listenersFailing = true
                log.error("cannot follow the host's listeners", metadata: ["error": "\(error)"])
            }
            return
        }
        for (mirror, relay) in running where !relay.isActive {
            running[mirror] = nil
            log.info("a host port relay closed; reopening it", metadata: ["port": "\(mirror.port)"])
        }
        for (mirror, relay) in running where !wanted.contains(mirror) {
            running[mirror] = nil
            await relay.closeNow()
            log.info("stopped relaying a host port", metadata: ["port": "\(mirror.port)"])
        }
        for mirror in wanted where running[mirror] == nil {
            do {
                let relay = try await open(mirror)
                guard pass == generation else {
                    await relay.closeNow()
                    return
                }
                running[mirror] = relay
                failures[mirror.port] = nil
                log.info("relaying a host port", metadata: ["port": "\(mirror.port)", "target": "\(mirror.target)"])
            } catch {
                // Another process may hold the port on the gateway: try again on the next pass.
                let reason = "\(error)"
                if failures[mirror.port] != reason {
                    failures[mirror.port] = reason
                    log.debug("cannot relay a host port yet", metadata: ["port": "\(mirror.port)", "error": "\(reason)"])
                }
            }
        }
        failures = failures.filter { port, _ in wanted.contains { $0.port == port } }
    }

    /// Closes every relay.
    public func stop() async {
        generation += 1
        let relays = Array(running.values)
        running.removeAll()
        for relay in relays { await relay.closeNow() }
    }
}
