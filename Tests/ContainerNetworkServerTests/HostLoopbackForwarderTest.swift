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
import NIO
import SocketForwarder
import Synchronization
import Testing

@testable import ContainerNetworkServer

struct HostLoopbackForwarderTest {
    private let group = MultiThreadedEventLoopGroup.singleton
    private let log = Logger(label: "HostLoopbackForwarderTest")

    // MARK: - What is relayed

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

    @Test func leavesOutPortsBelow1024WhichAGatewayAddressCannotTake() {
        let plan = HostLoopbackForwarder.plan([
            HostListener(address: .loopbackV4, port: 631), HostListener(address: .loopbackV6, port: 999),
            HostListener(address: .loopbackV4, port: 1023), HostListener(address: .loopbackV4, port: 1024),
        ])
        #expect(plan == [.init(port: 1024, target: .loopbackV4)])
    }

    @Test func relaysAtMostTheLowestSixtyFourPorts() {
        let listeners = (0..<100).map { HostListener(address: .loopbackV4, port: UInt16(20099 - $0)) }
        let plan = HostLoopbackForwarder.plan(listeners)
        #expect(plan.count == HostLoopbackForwarder.maximumPorts)
        #expect(plan.map(\.port).sorted() == (20000..<20064).map { UInt16($0) })
    }

    @Test func anInternalNetworkGetsNoRelay() {
        #expect(!HostLoopbackForwarder.relays(for: .hostOnly))
        #expect(HostLoopbackForwarder.relays(for: .nat))
    }

    @Test func servesOnlyClientsInsideTheNetwork() throws {
        let subnet = try CIDRv4("192.168.64.0/24")
        #expect(HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "192.168.64.7", port: 40000), subnet: subnet))
        #expect(!HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "192.168.68.20", port: 40000), subnet: subnet))
        #expect(!HostLoopbackForwarder.serves(try SocketAddress(ipAddress: "::1", port: 40000), subnet: subnet))
    }

    // MARK: - Reading the Mac's listeners

    @Test func onlyOneTwoSevenZeroZeroOneIsTheLoopbackTheRelayDials() {
        let zero6 = [UInt8](repeating: 0, count: 16)
        let one6 = [UInt8](repeating: 0, count: 15) + [1]
        #expect(HostListeners.classify(ipv4: true, v4Address: 0x7F00_0001, v6Address: zero6, port: 80).address == .loopbackV4)
        #expect(HostListeners.classify(ipv4: true, v4Address: 0x7F00_0002, v6Address: zero6, port: 80).address == .other)
        #expect(HostListeners.classify(ipv4: true, v4Address: 0, v6Address: zero6, port: 80).address == .anyV4)
        #expect(HostListeners.classify(ipv4: true, v4Address: 0xC0A8_4001, v6Address: zero6, port: 80).address == .other)
        #expect(HostListeners.classify(ipv4: false, v4Address: 0, v6Address: one6, port: 80).address == .loopbackV6)
        #expect(HostListeners.classify(ipv4: false, v4Address: 0, v6Address: zero6, port: 80).address == .other)
    }

    @Test func readsEveryKindOfListenerFromTheLiveTable() async throws {
        let loopback = try await Self.greeter(on: "127.0.0.1", group: group)
        let everywhere = try await Self.greeter(on: "0.0.0.0", group: group)
        let loopback6 = try await Self.greeter(on: "::1", group: group)
        let dualStack = try await Self.greeter(on: "::", group: group, v6Only: false)
        let v6Only = try await Self.greeter(on: "::", group: group, v6Only: true)
        defer {
            for server in [loopback, everywhere, loopback6, dualStack, v6Only] { server.channel.close(promise: nil) }
        }
        let listeners = Set(try HostListeners.current())
        #expect(listeners.contains(HostListener(address: .loopbackV4, port: loopback.port)))
        #expect(listeners.contains(HostListener(address: .anyV4, port: everywhere.port)))
        #expect(listeners.contains(HostListener(address: .loopbackV6, port: loopback6.port)))
        #expect(listeners.contains(HostListener(address: .anyV4, port: dualStack.port)))
        #expect(listeners.contains(HostListener(address: .other, port: v6Only.port)))
        #expect(!listeners.contains(HostListener(address: .anyV4, port: v6Only.port)))
    }

    // MARK: - Keeping the relays

    @Test func opensARelayForANewServiceAndClosesItWhenTheServiceGoes() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.channel.close(promise: nil) }
        let listening = Mutex<[HostListener]>([])
        let opener = Opener(group: group)
        let forwarder = HostLoopbackForwarder(listeners: { listening.withLock { $0 } }, open: opener.open, log: log)

        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)

        listening.withLock { $0 = [HostListener(address: .loopbackV4, port: backend.port)] }
        await forwarder.sync()
        #expect(await forwarder.ports == [backend.port])
        let proxy = try #require(opener.proxies.first)
        #expect(try await Self.read(from: proxy, group: group) == "hello from the Mac")

        // A second pass with nothing new keeps the one relay.
        await forwarder.sync()
        #expect(opener.proxies.count == 1)

        listening.withLock { $0 = [] }
        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)
        // sync waits for the listener to close, so nothing answers there any more.
        await #expect(throws: (any Error).self) { _ = try await Self.read(from: proxy, group: group) }
    }

    @Test func triesAPortItCouldNotHaveAgainOnTheNextPass() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.channel.close(promise: nil) }
        let opener = Opener(group: group, failFirst: 1)
        let forwarder = HostLoopbackForwarder(
            listeners: { [HostListener(address: .loopbackV4, port: backend.port)] }, open: opener.open, log: log)
        await forwarder.sync()
        #expect(await forwarder.ports.isEmpty)
        await forwarder.sync()
        #expect(await forwarder.ports == [backend.port])
        await forwarder.stop()
    }

    @Test func reopensARelayWhoseListenerClosed() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.channel.close(promise: nil) }
        let opener = Opener(group: group)
        let forwarder = HostLoopbackForwarder(
            listeners: { [HostListener(address: .loopbackV4, port: backend.port)] }, open: opener.open, log: log)
        await forwarder.sync()
        let first = try #require(opener.results.first)
        await first.closeNow()
        await forwarder.sync()
        #expect(opener.results.count == 2)
        #expect(await forwarder.ports == [backend.port])
        let proxy = try #require(opener.proxies.last)
        #expect(try await Self.read(from: proxy, group: group) == "hello from the Mac")
        await forwarder.stop()
    }

    @Test func dialsIPv4OnceAServiceListensThereToo() async throws {
        let listening = Mutex<[HostListener]>([HostListener(address: .loopbackV6, port: 40001)])
        let opener = Opener(group: group)
        let forwarder = HostLoopbackForwarder(listeners: { listening.withLock { $0 } }, open: opener.open, log: log)
        await forwarder.sync()
        #expect(await forwarder.mirrors == [.init(port: 40001, target: .loopbackV6)])
        listening.withLock { $0.append(HostListener(address: .loopbackV4, port: 40001)) }
        await forwarder.sync()
        #expect(await forwarder.mirrors == [.init(port: 40001, target: .loopbackV4)])
        #expect(opener.results.count == 2)
        #expect(opener.results.first?.isActive == false, "the IPv6 relay was closed")
        await forwarder.stop()
    }

    @Test func followsOnlyWhileContainersAreAttached() async throws {
        let calls = Counter()
        let forwarder = HostLoopbackForwarder(
            listeners: {
                calls.add()
                return []
            }, open: Opener(group: group).open, interval: .milliseconds(10), log: log)
        #expect(!(await forwarder.isFollowing))
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value == 0, "no container, no polling")
        await forwarder.attachmentsChanged(2)
        #expect(await forwarder.isFollowing)
        try await Self.until { calls.value >= 2 }
        await forwarder.attachmentsChanged(0)
        #expect(!(await forwarder.isFollowing))
        let after = calls.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.value <= after + 1, "polling stops with the last container")
    }

    // MARK: - The real relays

    @Test func theGatewayRelayDialsTheServiceOnIPv6Loopback() async throws {
        // A service on ::1 alone; the "gateway" is 127.0.0.1 here, the subnet all of 127/8.
        let backend = try await Self.greeter(on: "::1", group: group)
        defer { backend.channel.close(promise: nil) }
        let forwarder = HostLoopbackForwarder(
            gateway: try IPv4Address("127.0.0.1"), subnet: try CIDRv4("127.0.0.0/8"), eventLoopGroup: group, log: log,
            listeners: { [HostListener(address: .loopbackV6, port: backend.port)] })
        await forwarder.attachmentsChanged(1)
        try await Self.until { await forwarder.ports == [backend.port] }
        let gateway = try SocketAddress(ipAddress: "127.0.0.1", port: Int(backend.port))
        #expect(try await Self.read(from: gateway, group: group) == "hello from the Mac")
        await forwarder.attachmentsChanged(0)
        #expect(await forwarder.ports.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await Self.read(from: gateway, group: group) }
    }

    @Test func aRelayRefusesAClientOutsideTheNetworkWithoutDiallingTheMac() async throws {
        let backend = try await Self.greeter(on: "127.0.0.1", group: group)
        defer { backend.channel.close(promise: nil) }
        let subnet = try CIDRv4("192.168.64.0/24")
        let relay = try await TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: try #require(backend.channel.localAddress),
            eventLoopGroup: group,
            // The loopback client is not in the network's subnet.
            acceptsPeer: { HostLoopbackForwarder.serves($0, subnet: subnet) }
        ).run().get()
        defer { relay.close() }
        let proxy = try #require(relay.proxyAddress)
        #expect(try await Self.read(from: proxy, group: group, allowEmpty: true) == "")
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.accepted.value == 0, "the Mac's service never saw the client")
    }

    @Test func aRelayRefusesConnectionsBeyondTheLimit() async throws {
        let backend = try await Self.holder(group: group)
        defer { backend.channel.close(promise: nil) }
        let limit = ConnectionLimit(maximum: 1)
        let relay = try await TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: try #require(backend.channel.localAddress),
            eventLoopGroup: group,
            connectionLimit: limit
        ).run().get()
        defer { relay.close() }
        let proxy = try #require(relay.proxyAddress)

        let first = try await ClientBootstrap(group: group).connect(to: proxy).get()
        try await Self.until { limit.current == 1 && backend.accepted.value == 1 }
        // The second is closed at once, and never reaches the backend.
        #expect(try await Self.read(from: proxy, group: group, allowEmpty: true) == "")
        #expect(backend.accepted.value == 1)

        try await first.close().get()
        try await Self.until { limit.current == 0 }
        let third = try await ClientBootstrap(group: group).connect(to: proxy).get()
        try await Self.until { backend.accepted.value == 2 }
        try await third.close().get()
    }

    // MARK: - Helpers

    final class Counter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    struct Server {
        let channel: any Channel
        let accepted: Counter
        var port: UInt16 { UInt16(channel.localAddress!.port!) }
    }

    /// Opens real relays on ephemeral loopback ports, recording what it opened.
    final class Opener: Sendable {
        private let group: any EventLoopGroup
        private let state = Mutex<(results: [SocketForwarderResult], failures: Int)>(([], 0))
        private let failFirst: Int

        init(group: any EventLoopGroup, failFirst: Int = 0) {
            self.group = group
            self.failFirst = failFirst
        }

        var results: [SocketForwarderResult] { state.withLock { $0.results } }
        var proxies: [SocketAddress] { results.compactMap(\.proxyAddress) }

        var open: HostLoopbackForwarder.Open {
            { [self] mirror in
                let fail = state.withLock { state in
                    guard state.failures < failFirst else { return false }
                    state.failures += 1
                    return true
                }
                // The first binds fail, as one does when another process holds the port.
                if fail { throw IOError(errnoCode: EADDRINUSE, reason: "bind") }
                // A test has no gateway address: listen on an ephemeral loopback port instead.
                let target = mirror.target == .loopbackV6 ? "::1" : "127.0.0.1"
                let relay = try await TCPForwarder(
                    proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
                    serverAddress: try SocketAddress(ipAddress: target, port: Int(mirror.port)),
                    eventLoopGroup: group
                ).run().get()
                state.withLock { $0.results.append(relay) }
                return relay
            }
        }
    }

    /// A server that greets each client and hangs up.
    private static func greeter(on host: String, group: any EventLoopGroup, v6Only: Bool? = nil) async throws -> Server {
        let accepted = Counter()
        var bootstrap = ServerBootstrap(group: group)
        if let v6Only {
            bootstrap = bootstrap.serverChannelOption(
                ChannelOptions.socket(.init(IPPROTO_IPV6), .init(IPV6_V6ONLY)), value: v6Only ? 1 : 0)
        }
        let channel =
            try await bootstrap
            .childChannelInitializer { channel in
                accepted.add()
                return channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Greeter()) }
            }
            .bind(host: host, port: 0).get()
        return Server(channel: channel, accepted: accepted)
    }

    /// A server that keeps each connection open and says nothing.
    private static func holder(group: any EventLoopGroup) async throws -> Server {
        let accepted = Counter()
        let channel =
            try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                accepted.add()
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return Server(channel: channel, accepted: accepted)
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

    /// Waits, a few seconds at most, for a condition the event loops make true.
    private static func until(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met in time")
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
