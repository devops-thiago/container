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
import Testing

@testable import ContainerCommands

struct StreamRelayTests {
    /// The descriptors of one relay under test: what it reads and writes as its standard
    /// streams, and the application's end of the socket.
    private struct Wiring {
        let toInput: Int32
        let fromOutput: Int32
        let application: Int32
        let relay: Thread
        let finished: DispatchSemaphore
    }

    private func wire() throws -> Wiring {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var pair: [Int32] = [0, 0]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let finished = DispatchSemaphore(value: 0)
        let (readEnd, writeEnd, relayEnd) = (input[0], output[1], pair[0])
        let relay = Thread {
            StreamRelay.run(input: readEnd, output: writeEnd, socket: relayEnd)
            close(relayEnd)
            close(writeEnd)
            finished.signal()
        }
        relay.start()
        return Wiring(toInput: input[1], fromOutput: output[0], application: pair[1], relay: relay, finished: finished)
    }

    private func send(_ text: String, to descriptor: Int32) {
        let bytes = Array(text.utf8)
        #expect(write(descriptor, bytes, bytes.count) == bytes.count)
    }

    /// Waits for `descriptor` to have something to read, or an end, for up to ten seconds.
    /// A read that would wait longer is a hang, and a hang here held the whole suite once;
    /// it is reported instead.
    private func readable(_ descriptor: Int32, _ what: String) -> Bool {
        var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&waiting, 1, 10_000)
        #expect(ready == 1, "nothing to read from \(what) within ten seconds")
        return ready == 1
    }

    private func receive(_ count: Int, from descriptor: Int32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count, readable(descriptor, "the relay") {
            let result = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + got, count - got) }
            guard result > 0 else { break }
            got += result
        }
        return String(decoding: bytes.prefix(got), as: UTF8.self)
    }

    @Test
    func bytesGoBothWays() throws {
        let wiring = try wire()
        send("GET /_ping HTTP/1.1\r\n\r\n", to: wiring.application)
        #expect(receive(23, from: wiring.fromOutput) == "GET /_ping HTTP/1.1\r\n\r\n")
        send("HTTP/1.1 200 OK\r\n\r\n", to: wiring.toInput)
        #expect(receive(19, from: wiring.application) == "HTTP/1.1 200 OK\r\n\r\n")

        close(wiring.application)
        #expect(wiring.finished.wait(timeout: .now() + 5) == .success, "the application closing ends the relay")
        close(wiring.toInput)
        close(wiring.fromOutput)
    }

    @Test
    func theEndOfInputIsPassedOnAndTheAnswerStillArrives() throws {
        let wiring = try wire()
        send("last words", to: wiring.toInput)
        close(wiring.toInput)
        #expect(receive(10, from: wiring.application) == "last words")
        var byte: UInt8 = 0
        #expect(readable(wiring.application, "the application's end") && read(wiring.application, &byte, 1) == 0, "the application reads the end of what the tool sent")

        // The relay is still listening to the application, whose answer is copied out.
        send("goodbye", to: wiring.application)
        #expect(receive(7, from: wiring.fromOutput) == "goodbye")
        close(wiring.application)
        #expect(wiring.finished.wait(timeout: .now() + 5) == .success)
        close(wiring.fromOutput)
    }

    @Test
    func aLargeStreamArrivesWhole() throws {
        let wiring = try wire()
        let block = String(repeating: "0123456789abcdef", count: 4096)
        let sender = Thread {
            for _ in 0..<32 { self.send(block, to: wiring.toInput) }
            close(wiring.toInput)
        }
        sender.start()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while readable(wiring.application, "the stream") {
            let count = read(wiring.application, &buffer, buffer.count)
            guard count > 0 else { break }
            total += count
        }
        #expect(total == block.utf8.count * 32)
        close(wiring.application)
        #expect(wiring.finished.wait(timeout: .now() + 5) == .success)
        close(wiring.fromOutput)
    }

    @Test func peerClosureEndsASenderUnderBackpressure() throws {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var pair: [Int32] = [0, 0]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var size: Int32 = 1024
        try #require(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0)
        let inputRead = input[0]
        let inputWrite = input[1]
        let outputWrite = output[1]
        let socket = pair[0]
        let finished = DispatchSemaphore(value: 0)
        let produced = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            StreamRelay.run(input: inputRead, output: outputWrite, socket: socket)
            finished.signal()
        }
        Thread.detachNewThread {
            let bytes = [UInt8](repeating: 42, count: 1_048_576)
            _ = write(inputWrite, bytes, bytes.count)
            produced.signal()
        }
        // Seeing input at the peer proves the sender is running. Leave that data unread
        // so the sender has to wait for room while the receiving direction ends.
        try #require(readable(pair[1], "the blocked sender"))
        shutdown(pair[1], SHUT_WR)
        #expect(finished.wait(timeout: .now() + 5) == .success)
        shutdown(pair[1], SHUT_RDWR)
        close(inputRead)
        close(inputWrite)
        #expect(produced.wait(timeout: .now() + 5) == .success)
        for fd in output + pair { close(fd) }
    }

    @Test func lateInputCannotWriteToAReusedSocketDescriptor() throws {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var pair: [Int32] = [0, 0]
        var replacement: [Int32] = [0, 0]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        try #require(pipe(&replacement) == 0)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let inputRead = input[0]
        let outputWrite = output[1]
        let socket = pair[0]
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            StreamRelay.run(input: inputRead, output: outputWrite, socket: socket)
            finished.signal()
        }
        defer {
            for fd in input + output + pair + replacement { close(fd) }
        }
        send("ready", to: input[1])
        #expect(receive(5, from: pair[1]) == "ready")
        shutdown(pair[1], SHUT_WR)
        try #require(finished.wait(timeout: .now() + 5) == .success)
        #expect(fcntl(socket, F_GETFL) & O_NONBLOCK == 0, "the caller receives its original socket flags")
        // Reuse exactly the descriptor the caller is now allowed to close.
        try #require(dup2(replacement[1], socket) == socket)
        send("late", to: input[1])
        var waiting = pollfd(fd: replacement[0], events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 250) == 0, "late input must not reach an unrelated descriptor")
        var pending = pollfd(fd: input[0], events: Int16(POLLIN), revents: 0)
        #expect(poll(&pending, 1, 250) == 1, "the sending worker must be gone, not merely dropping later input")
    }

    @Test(arguments: [
        ("import.sock", true), ("a-b_c.1.sock", true), (".sock", false), (".hidden.sock", false), ("import", false), ("../import.sock", false), ("run/import.sock", false),
        ("", false), ("im port.sock", false),
    ])
    func aSocketNameIsOnePathComponent(_ name: String, _ valid: Bool) {
        #expect(StreamRelay.nameValid(name) == valid)
    }

    @Test
    func itConnectsByNameFromInsideTheFolder() throws {
        // A folder whose path alone is longer than a socket address holds.
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString)")
            .appendingPathComponent(String(repeating: "long-folder-name-", count: 6))
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deep.deletingLastPathComponent()) }
        let home = FileManager.default.currentDirectoryPath
        defer { _ = chdir(home) }
        #expect(deep.path.utf8.count > 104)

        #expect(throws: (any Error).self) { try StreamRelay.connect(name: "nobody.sock", in: deep.path) }

        // A listener bound the same way: by name, from inside the folder.
        try #require(chdir(deep.path) == 0)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in "waiting.sock".utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        defer { close(listener) }
        _ = chdir(home)

        let connected = try StreamRelay.connect(name: "waiting.sock", in: deep.path)
        #expect(connected >= 0)
        close(connected)
        #expect(throws: (any Error).self) { try StreamRelay.connect(name: "../waiting.sock", in: deep.path) }
    }
}
