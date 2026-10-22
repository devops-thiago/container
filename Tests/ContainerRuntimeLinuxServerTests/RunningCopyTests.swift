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

import ContainerizationError
import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct RunningCopyTests {
    typealias FakeAgent = PrestartCopyTests.FakeAgent
    static let rootfs = PrestartCopyTests.rootfs
    static let directory = PrestartCopyTests.directory
    static let file = PrestartCopyTests.file

    @Test("a copy in resolves its destination as containerization's copyIn does, in the root filesystem")
    func destinations() async throws {
        let source = try PrestartCopyTests.Source()
        let agent = FakeAgent(["/tmp": Self.directory, "/etc/motd": Self.file])
        try await RunningCopy.copyIn(
            from: source.file, to: URL(fileURLWithPath: "/tmp/"), mode: 0o600, createParents: true, rootfs: Self.rootfs, agent: agent)
        try await RunningCopy.copyIn(
            from: source.file, to: URL(fileURLWithPath: "/etc/motd"), mode: 0, createParents: false, rootfs: Self.rootfs, agent: agent)
        try await RunningCopy.copyIn(
            from: source.directory, to: URL(fileURLWithPath: "/srv/new"), mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        #expect(
            await agent.copies == [
                .init(isDirectory: false, root: Self.rootfs, path: "/tmp/hello.txt", mode: 0o600, createParents: true),
                .init(isDirectory: false, root: Self.rootfs, path: "/etc/motd", mode: 0, createParents: false),
                .init(isDirectory: true, root: Self.rootfs, path: "/srv/new", mode: 0, createParents: true),
            ])
        #expect(await agent.identityRoots == [Self.rootfs, Self.rootfs, Self.rootfs])
    }

    @Test("a file to a missing directory and a directory over a file are refused, and nothing is copied")
    func refusals() async throws {
        let source = try PrestartCopyTests.Source()
        let agent = FakeAgent(["/etc/motd": Self.file])
        await #expect {
            try await RunningCopy.copyIn(
                from: source.file, to: URL(fileURLWithPath: "/missing/"), mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("destination directory does not exist") == true
        }
        await #expect {
            try await RunningCopy.copyIn(
                from: source.directory, to: URL(fileURLWithPath: "/etc/motd"), mode: 0, createParents: true, rootfs: Self.rootfs, agent: agent)
        } throws: { error in
            (error as? ContainerizationError)?.message.contains("cannot copy directory over existing file") == true
        }
        await #expect(throws: ContainerizationError.self) {
            try await RunningCopy.copyIn(
                from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), to: URL(fileURLWithPath: "/tmp"), mode: 0,
                createParents: true, rootfs: Self.rootfs, agent: agent)
        }
        #expect(await agent.copies.isEmpty)
    }

    @Test("a copy out makes the destination's parents and asks for the container's path in its root filesystem")
    func copyOut() async throws {
        let source = try PrestartCopyTests.Source()
        let destination = source.top.appending(path: "a/b/out.txt")
        let agent = FakeAgent()
        try await RunningCopy.copyOut(from: "/var/log/app.log", to: destination, createParents: true, rootfs: Self.rootfs, agent: agent)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: source.top.appending(path: "a/b").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let asked = await agent.copiesOut
        #expect(asked.count == 1)
        #expect(asked.first?.root == Self.rootfs)
        #expect(asked.first?.path == "/var/log/app.log")
        #expect(asked.first?.destination == destination)
    }

    @Test("a stop cancels the running copies and waits for each to end", .timeLimit(.minutes(1)))
    func cancelAllWaits() async throws {
        let copies = ActiveCopies()
        let ended = Mutex(0)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let callers = (0..<2).map { _ in
            Task {
                try await copies.run {
                    defer { ended.withLock { $0 += 1 } }
                    startedContinuation.yield(())
                    try await Task.sleep(for: .seconds(120))
                }
            }
        }
        var count = 0
        for await _ in started {
            count += 1
            if count == 2 { break }
        }
        #expect(copies.count == 2)
        await copies.cancelAll()
        #expect(ended.withLock { $0 } == 2)
        for caller in callers {
            await #expect {
                try await caller.value
            } throws: { error in
                (error as? ContainerizationError)?.code == .invalidState
                    && (error as? ContainerizationError)?.message.contains("the container stopped during the copy") == true
            }
        }
        #expect(copies.count == 0)
    }

    @Test("cancelling the caller cancels its copy", .timeLimit(.minutes(1)))
    func callerCancels() async throws {
        let copies = ActiveCopies()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let caller = Task {
            try await copies.run {
                startedContinuation.yield(())
                try await Task.sleep(for: .seconds(120))
            }
        }
        for await _ in started { break }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(copies.count == 0)
    }

    /// A connected pair of stream sockets standing in for the copy's vsock connection: the
    /// copy's end, and the guest's.
    static func connection() throws -> (copy: FileHandle, guest: FileHandle) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: false), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    @Test("a cancelled copy in stops sending at once and the guest sees its end", .timeLimit(.minutes(1)))
    func cancelledSendEnds() async throws {
        let source = try PrestartCopyTests.Source()
        // More than the socket buffers hold, to a guest that reads nothing: the send blocks.
        // Random, so that the archive's compression does not shrink it to what they hold.
        var noise = Data(count: 64 << 20)
        noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try noise.write(to: source.file)
        let (copy, guest) = try Self.connection()
        let send = Task { try await VminitdCopyAgent.send(source.file, isDirectory: false, name: "hello.txt", mode: 0, owner: nil, to: copy) }
        try await Task.sleep(for: .milliseconds(300))
        send.cancel()
        await #expect(throws: (any Error).self) { try await send.value }
        // The guest drains what was buffered, then reaches the end of the stream.
        let drained = try guest.readToEnd() ?? Data()
        #expect(drained.count < 64 << 20)
    }

    @Test("a cancelled copy out stops waiting for the guest at once", .timeLimit(.minutes(1)))
    func cancelledReceiveEnds() async throws {
        let source = try PrestartCopyTests.Source()
        let (copy, guest) = try Self.connection()
        let receive = Task {
            try await VminitdCopyAgent.receive(to: source.top.appending(path: "out.bin"), isArchive: false, from: copy)
        }
        try await Task.sleep(for: .milliseconds(300))
        receive.cancel()
        await #expect(throws: (any Error).self) { try await receive.value }
        _ = guest
    }

    @Test("a copy out writes a file's bytes, and unpacks a directory's archive into the destination")
    func receivePayloads() async throws {
        let source = try PrestartCopyTests.Source()
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: source.file)
        let (fileCopy, fileGuest) = try Self.connection()
        let fileOut = source.top.appending(path: "file.out")
        async let received: Void = VminitdCopyAgent.receive(to: fileOut, isArchive: false, from: fileCopy)
        try fileGuest.write(contentsOf: bytes)
        try fileGuest.close()
        try await received
        #expect(try Data(contentsOf: fileOut) == bytes)

        try Data("nested contents\n".utf8).write(to: source.directory.appending(path: "inner.txt"))
        let (sendEnd, receiveEnd) = try Self.connection()
        let directoryOut = source.top.appending(path: "dir.out")
        async let sent: Void = VminitdCopyAgent.send(source.directory, isDirectory: true, name: ".", mode: 0, owner: nil, to: sendEnd)
        async let unpacked: Void = VminitdCopyAgent.receive(to: directoryOut, isArchive: true, from: receiveEnd)
        try await sent
        try await unpacked
        #expect(try String(contentsOf: directoryOut.appending(path: "inner.txt"), encoding: .utf8) == "nested contents\n")
    }
}
