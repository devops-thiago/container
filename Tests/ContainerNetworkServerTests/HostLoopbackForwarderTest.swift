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

import ContainerNetworkServer
import ContainerizationExtras
import Logging
import NIO
import SocketForwarder
import Synchronization
import Testing

struct HostLoopbackForwarderTest {
    private let group = MultiThreadedEventLoopGroup.singleton
    private let log = Logger(label: "HostLoopbackForwarderTest")

    @Test func relaysLoopbackOnlyPortsAndLeavesWildcardOnesToTheGateway() {
        let plan = HostLoopbackForwarder.plan([
            HostListener(address: .loopbackV4, port: 11434),
            HostListener(address: .loopbackV4, port: 8021), HostListener(address: .loopbackV6, port: 8021),
            HostListener(address: .loopbackV6, port: 4330),
            HostListener(address: .loopbackV4, port: 5000), HostListener(address: .anyV4, port: 5000),
            HostListener(address: .other, port: 7000),
        ])
        #expect(
            plan == [
                .init(port: 11434, target: .loopbackV4), .init(port: 8021, target: .loopbackV4), .init(port: 4330, target: .loopbackV6),
            ])
    }

    @Test func servesOnlyClientsInsideTheNetwork() throws {
        let subnet = try CIDRv4("192.168.64.0/24")
        #expect(HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "192.168.64.7", port: 40000), subnet: subnet))
        #expect(!HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "192.168.68.20", port: 40000), subnet: subnet))
        #expect(!HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "::1", port: 40000), subnet: subnet))
    }

    @Test func seesAServiceListeningOnLoopbackAndOneOnEveryAddress() async throws {
        let loopback = try await Self.greeter(on: "127.0.0.1", group: group)
        let everywhere = try await Self.greeter(on: "0.0.0.0", group: group)
        defer {
            loopback.close(promise: nil)
            everywhere.close(promise: nil)
        }
        let listeners = try HostListeners.current()
        let loopbackPort = try #require(loopback.localAddress?.port).asPort
        let everywherePort = try #require(everywhere.localAddress?.port).asPort
        #expect(listeners.contains(HostListener(address: .loopbackV4, port: loopbackPort)))
        #expect(listeners.contains(HostListener(address: .anyV4, port: everywherePort)))
        #expect(!listeners.contains(HostListener(address: .loopbackV4, port: everywherePort)))
    }

    @Test func opensARelayForANewServiceAndClosesItWhenTheServiceGoes() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.close(promise: nil) }
        let port = try #require(backend.localAddress?.port).asPort
        let listening = Mutex<[HostListener]>([])
        let proxies = Mutex<[SocketAddress]>([])
        let forwarder = HostLoopbackForwarder(
            listeners: { listening.withLock { $0 } },
            open: { [group] mirror in
                // A test has no gateway address: listen on an ephemeral loopback port instead.
                let relay = try await TCPForwarder(
                    proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
                    serverAddress: try SocketAddress(ipAddress: "127.0.0.1", port: Int(mirror.port)),
                    eventLoopGroup: group
                ).run().get()
                proxies.withLock { $0.append(relay.proxyAddress!) }
                return relay
            },
            log: log)

        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)

        listening.withLock { $0 = [HostListener(address: .loopbackV4, port: port)] }
        await forwarder.sync()
        #expect(await forwarder.ports == [port])
        let proxy = try #require(proxies.withLock { $0.first })
        #expect(try await Self.read(from: proxy, group: group) == "hello from the Mac")

        // A second pass with nothing new keeps the one relay.
        await forwarder.sync()
        #expect(proxies.withLock { $0.count } == 1)

        listening.withLock { $0 = [] }
        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await Self.read(from: proxy, group: group) }
    }

    @Test func triesAPortItCouldNotHaveAgainOnTheNextPass() async throws {
        let attempts = Mutex(0)
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.close(promise: nil) }
        let port = try #require(backend.localAddress?.port).asPort
        let forwarder = HostLoopbackForwarder(
            listeners: { [HostListener(address: .loopbackV4, port: port)] },
            open: { [group] mirror in
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                // The first bind fails, as it does before the bridge is up.
                if attempt == 1 { throw IOError(errnoCode: EADDRNOTAVAIL, reason: "bind") }
                return try await TCPForwarder(
                    proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
                    serverAddress: try SocketAddress(ipAddress: "127.0.0.1", port: Int(mirror.port)),
                    eventLoopGroup: group
                ).run().get()
            },
            log: log)
        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)
        await forwarder.sync()
        #expect(await forwarder.ports == [port])
        await forwarder.stop()
    }

    @Test func aRelayRefusesAClientOutsideTheNetwork() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.close(promise: nil) }
        let subnet = try CIDRv4("192.168.64.0/24")
        let relay = try await TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: try #require(backend.localAddress),
            eventLoopGroup: group,
            // The loopback client is not in the network's subnet.
            acceptsPeer: { HostLoopbackForwarder.serves($0, subnet: subnet) }
        ).run().get()
        defer { relay.close() }
        let proxy = try #require(relay.proxyAddress)
        #expect(try await Self.read(from: proxy, group: group, allowEmpty: true) == "")
    }

    // MARK: - Helpers

    /// A server that greets each client and hangs up.
    private static func greeter(on host: String, group: any EventLoopGroup) async throws -> any Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Greeter()) }
            }
            .bind(host: host, port: 0).get()
    }

    /// Everything a server at `address` sends before it hangs up.
    private static func read(from address: SocketAddress, group: any EventLoopGroup, allowEmpty: Bool = false) async throws -> String {
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(2))
            .connect(to: address) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        var text = ""
        try await channel.executeThenClose { inbound, _ in
            for try await buffer in inbound { text += String(buffer: buffer) }
        }
        if text.isEmpty && !allowEmpty { throw IOError(errnoCode: ECONNRESET, reason: "no greeting") }
        return text
    }
}

private final class Greeter: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: "hello from the Mac")
        context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
        context.close(promise: nil)
    }
}

extension Int {
    fileprivate var asPort: UInt16 { UInt16(self) }
}
