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

import ContainerPersistence
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage
import Testing
import XPC

@testable import ContainerAPIClient
@testable import MachineAPIClient
@testable import MachineAPIService

actor MachineRuntimeFixture {
    private(set) var stops: [String] = []
    private var stopped: Set<String> = []
    private var incarnations: [String: String] = [:]

    func create(_ id: String, incarnation: String) { incarnations[id] = incarnation }

    func replace(_ id: String) { incarnations[id] = UUID().uuidString }

    private var waits: [String: CheckedContinuation<Int32, Never>] = [:]

    func wait(_ id: String) async -> Int32 {
        if stopped.contains(id) { return 0 }
        return await withCheckedContinuation { waits[id] = $0 }
    }

    func stop(_ id: String, expected: String?) throws {
        if let expected, incarnations[id] != expected {
            throw ContainerizationError(.invalidState, message: "container incarnation changed")
        }
        stops.append(id)
        stopped.insert(id)
        waits.removeValue(forKey: id)?.resume(returning: 0)
    }

    func close() {
        for (id, continuation) in waits {
            stopped.insert(id)
            continuation.resume(returning: 0)
        }
        waits.removeAll()
    }
}

final class MachineSetupFixture: @unchecked Sendable {
    let root: URL
    let runtime = MachineRuntimeFixture()
    let service: MachinesService
    let client: MachineClient
    let bundle: MachineBundle
    private let engineTransport: XPCClient
    private let machineTransport: XPCClient
    private let listeners: [xpc_connection_t]
    let setupDisconnectEvents: AsyncStream<Void>
    private let setupDisconnectContinuation: AsyncStream<Void>.Continuation
    let bootReplyEvents: AsyncStream<Void>
    private let bootReplyContinuation: AsyncStream<Void>.Continuation
    private let bootReplyHoldContinuation: AsyncStream<Void>.Continuation
    let inspectionEvents: AsyncStream<Void>
    private let inspectionHoldContinuation: AsyncStream<Void>.Continuation
    private let inspectionContinuation: AsyncStream<Void>.Continuation
    private let tasks: [Task<Void, any Error>]

    init(holdInspections: Bool = false, holdBootReply: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-setup-\(UUID())")
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("fixture init; never executed".utf8).write(to: resources.appendingPathComponent("init"))
        let kernel = resources.appendingPathComponent("kernel")
        try Data("fixture kernel; no VM is created".utf8).write(to: kernel)
        let config = try MachineConfiguration(
            id: "fixture",
            image: ImageDescription(
                reference: "fixture:latest",
                descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "a", count: 64), size: 0)),
            platform: .init(arch: "arm64", os: "linux", variant: nil), userSetup: UserSetup(username: "developer", uid: 1000, gid: 1000))
        let bootConfig = try MachineConfig(cpus: 1, memory: nil, homeMount: MachineConfig.HomeMountOption.none, virtualization: false, kernelPath: FilePath(kernel.path))
        let path = FilePath(root.appendingPathComponent("machines/fixture").path)
        bundle = try MachineBundle.create(path: path, machineConfiguration: config, resourceRoot: FilePath(resources.path), bootConfig: bootConfig)
        let filesystem = Filesystem.block(format: "ext4", source: root.appendingPathComponent("unused-rootfs").path, destination: "/", options: [])
        try JSONEncoder().encode(filesystem).write(to: URL(fileURLWithPath: path.appending("rootfs.json").string))

        let runtime = self.runtime
        let engineListener = xpc_connection_create(nil, nil)
        let engineServer = XPCServer(
            connection: engineListener,
            routes: [
                XPCRoute.containerList.rawValue: XPCServer.route { $0.reply() },
                XPCRoute.containerCreate.rawValue: XPCServer.route { request in
                    let config = try JSONDecoder().decode(ContainerConfiguration.self, from: try #require(request.dataNoCopy(key: XPCKeys.containerConfig.rawValue)))
                    let incarnation = try #require(request.string(key: XPCKeys.expectedIncarnation.rawValue))
                    await runtime.create(config.id, incarnation: incarnation)
                    let reply = request.reply()
                    reply.set(key: XPCKeys.expectedIncarnation.rawValue, value: incarnation)
                    return reply
                },
                XPCRoute.containerDelete.rawValue: XPCServer.route { $0.reply() },
                XPCRoute.containerBootstrap.rawValue: XPCServer.route { $0.reply() },
                XPCRoute.containerStartProcess.rawValue: XPCServer.route { $0.reply() },
                XPCRoute.containerStop.rawValue: XPCServer.route { request in
                    try await runtime.stop(try #require(request.string(key: XPCKeys.id.rawValue)), expected: request.string(key: XPCKeys.expectedIncarnation.rawValue))
                    return request.reply()
                },
                XPCRoute.containerWait.rawValue: XPCServer.route { request in
                    let status = await runtime.wait(try #require(request.string(key: XPCKeys.id.rawValue)))
                    let reply = request.reply()
                    reply.set(key: XPCKeys.exitCode.rawValue, value: Int64(status))
                    return reply
                },
                XPCRoute.containerLogs.rawValue: XPCServer.route { request in
                    let handles = [try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")), try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))]
                    defer { for handle in handles { try? handle.close() } }
                    let reply = request.reply()
                    try reply.set(key: XPCKeys.logs.rawValue, value: handles)
                    return reply
                },
                "fixture-ready": XPCServer.route { $0.reply() },
            ], log: Logger(label: "machine-engine-fixture"))
        nonisolated(unsafe) let engineEndpoint = xpc_endpoint_create(engineListener)
        engineTransport = XPCClient(endpoint: engineEndpoint, label: "machine-engine-fixture")
        service = try MachinesService(
            appRoot: FilePath(root.path), resourceRoot: FilePath(resources.path), log: Logger(label: "machine-service-fixture"),
            client: ContainerClient(
                xpcClient: engineTransport,
                makeGrantAwareClient: {
                    XPCClient(endpoint: engineEndpoint, label: "machine-grant-request-fixture")
                }), bootSettings: { _ in ("default", nil) })
        let harness = MachinesHarness(service: service)
        let disconnected = AsyncStream<Void>.makeStream()
        setupDisconnectEvents = disconnected.stream
        setupDisconnectContinuation = disconnected.continuation
        let bootReplies = AsyncStream<Void>.makeStream()
        bootReplyEvents = bootReplies.stream
        bootReplyContinuation = bootReplies.continuation
        let heldBootReply = AsyncStream<Void>.makeStream()
        bootReplyHoldContinuation = heldBootReply.continuation
        let inspections = AsyncStream<Void>.makeStream()
        inspectionEvents = inspections.stream
        inspectionContinuation = inspections.continuation
        let heldInspection = AsyncStream<Void>.makeStream()
        inspectionHoldContinuation = heldInspection.continuation
        let machineListener = xpc_connection_create(nil, nil)
        let machineServer = XPCServer(
            connection: machineListener,
            routes: [
                MachineRoutes.bootMachine.rawValue: XPCServer.route(harness.boot),
                MachineRoutes.bootMachineForSetup.rawValue: { request, session in
                    let reply = try await harness.bootForSetup(request, session: session)
                    await session.onDisconnect { disconnected.continuation.yield(()) }
                    bootReplies.continuation.yield(())
                    if holdBootReply {
                        var next = heldBootReply.stream.makeAsyncIterator()
                        _ = await next.next()
                    }
                    return reply
                },
                MachineRoutes.completeMachineSetup.rawValue: XPCServer.route(harness.completeSetup),
                MachineRoutes.stopMachineSetup.rawValue: XPCServer.route(harness.stopSetup),
                MachineRoutes.stopMachine.rawValue: XPCServer.route(harness.stop),
                MachineRoutes.inspectMachine.rawValue: XPCServer.route { request in
                    let reply = try await harness.inspect(request)
                    inspections.continuation.yield(())
                    if holdInspections {
                        var next = heldInspection.stream.makeAsyncIterator()
                        _ = await next.next()
                    }
                    return reply
                },
                "fixture-ready": XPCServer.route { $0.reply() },
            ], log: Logger(label: "machine-client-fixture"))
        nonisolated(unsafe) let machineEndpoint = xpc_endpoint_create(machineListener)
        machineTransport = XPCClient(endpoint: machineEndpoint, label: "machine-client-fixture")
        client = MachineClient(
            xpcClient: machineTransport,
            setupClientFactory: { XPCClient(endpoint: machineEndpoint, label: "owned-machine-setup-fixture") })
        listeners = [engineListener, machineListener]
        tasks = [Task { try await engineServer.listen() }, Task { try await machineServer.listen() }]
    }

    func additionalClient() -> (MachineClient, XPCClient) {
        let transport = XPCClient(endpoint: xpc_endpoint_create(listeners[1]), label: "additional-machine-client-fixture")
        return (MachineClient(xpcClient: transport), transport)
    }

    func ready() async throws {
        _ = try await engineTransport.send(XPCMessage(route: "fixture-ready"))
        _ = try await machineTransport.send(XPCMessage(route: "fixture-ready"))
    }

    func releaseInspections() { inspectionHoldContinuation.finish() }
    func releaseBootReplies() { bootReplyHoldContinuation.finish() }

    func close() async {
        inspectionContinuation.finish()
        setupDisconnectContinuation.finish()
        bootReplyContinuation.finish()
        bootReplyHoldContinuation.finish()
        inspectionHoldContinuation.finish()
        try? await service.stop(id: "fixture")
        await runtime.close()
        engineTransport.close()
        machineTransport.close()
        for listener in listeners { xpc_connection_cancel(listener) }
        for task in tasks { task.cancel() }
        try? FileManager.default.removeItem(at: root)
    }
}
