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

import ContainerizationExtras
import Logging
import NIOCore
import SocketForwarder

/// Makes the Mac's loopback services reachable from the network's containers at the gateway,
/// which is where `host.docker.internal` points, as Docker Desktop does.
///
/// macOS gives an unprivileged, sandboxed process no way to take connections for every port of
/// an address (that needs `pf`, and root). So the helper follows the Mac's listeners instead:
/// it reads the kernel's table of TCP listeners every `interval`, and for each port a service
/// listens on at `127.0.0.1` or `::1` alone it listens on the gateway address (the bridge
/// interface of this network, never a wildcard) and relays each connection to that loopback
/// port. Only clients inside the network's subnet are served, so a machine on the Mac's LAN
/// that routes to the bridge gets nothing.
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

    /// The relays the listeners call for: one per port with a loopback listener and none on
    /// every IPv4 address (the gateway already reaches that one), dialling `127.0.0.1` when a
    /// service listens there and `::1` otherwise.
    public static func plan(_ listeners: [HostListener]) -> Set<Mirror> {
        var reachable: Set<UInt16> = []
        var v4: Set<UInt16> = []
        var v6: Set<UInt16> = []
        for listener in listeners {
            switch listener.address {
            case .anyV4: reachable.insert(listener.port)
            case .loopbackV4: v4.insert(listener.port)
            case .loopbackV6: v6.insert(listener.port)
            case .other: break
            }
        }
        var mirrors: Set<Mirror> = []
        for port in v4.union(v6).subtracting(reachable) {
            mirrors.insert(Mirror(port: port, target: v4.contains(port) ? .loopbackV4 : .loopbackV6))
        }
        return mirrors
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

    /// The real relays: listen on `gateway`, serve `subnet`, dial the loopback address.
    public init(gateway: IPv4Address, subnet: CIDRv4, eventLoopGroup: any EventLoopGroup, log: Logger) {
        let open: Open = { mirror in
            let target = mirror.target == .loopbackV6 ? "::1" : "127.0.0.1"
            let forwarder = try TCPForwarder(
                proxyAddress: try SocketAddress(ipAddress: gateway.description, port: Int(mirror.port)),
                serverAddress: try SocketAddress(ipAddress: target, port: Int(mirror.port)),
                eventLoopGroup: eventLoopGroup,
                log: log,
                acceptsPeer: { Self.serves($0, subnet: subnet) })
            return try await forwarder.run().get()
        }
        self.init(listeners: HostListeners.current, open: open, log: log)
    }

    /// Whether a client belongs to the network: an IPv4 address inside its subnet.
    public static func serves(_ peer: SocketAddress, subnet: CIDRv4) -> Bool {
        guard case .v4 = peer, let text = peer.ipAddress, let address = try? IPv4Address(text) else { return false }
        return subnet.contains(address)
    }

    /// The ports relayed now.
    public var ports: Set<UInt16> { Set(running.keys.map(\.port)) }

    /// Follows the Mac's listeners until the task is cancelled, then closes every relay.
    public func run() async {
        while !Task.isCancelled {
            await sync()
            try? await Task.sleep(for: interval)
        }
        stop()
    }

    /// Brings the relays in line with the listeners of the moment, once.
    public func sync() async {
        let wanted: Set<Mirror>
        do {
            wanted = Self.plan(try listeners())
        } catch {
            log.error("cannot follow the host's listeners", metadata: ["error": "\(error)"])
            return
        }
        for (mirror, relay) in running where !relay.isActive {
            running[mirror] = nil
            log.info("a host port relay closed; reopening it", metadata: ["port": "\(mirror.port)"])
        }
        for (mirror, relay) in running where !wanted.contains(mirror) {
            relay.close()
            running[mirror] = nil
            log.info("stopped relaying a host port", metadata: ["port": "\(mirror.port)"])
        }
        for mirror in wanted where running[mirror] == nil {
            do {
                running[mirror] = try await open(mirror)
                failures[mirror.port] = nil
                log.info("relaying a host port", metadata: ["port": "\(mirror.port)", "target": "\(mirror.target)"])
            } catch {
                // The bridge is not up before the first container joins, and another process
                // may hold the port on the gateway: try again on the next pass.
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
    public func stop() {
        for relay in running.values { relay.close() }
        running.removeAll()
    }
}
