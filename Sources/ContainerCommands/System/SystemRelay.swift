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

import ArgumentParser
import ContainerAPIClient
import ContainerVersion
import ContainerizationError
import Foundation
import Synchronization

extension Application {
    /// Passes standard input and output on to a socket the embedding application listens on.
    ///
    /// A sandboxed process cannot connect to a socket outside its own containers, and it
    /// can talk over any descriptor it is started with. So a tool that speaks on its own
    /// standard streams is put in touch with the application by a shell: the shell pipes
    /// the tool to this command, and this command passes the bytes on to a socket in the
    /// application group container, where the application waits.
    public struct SystemRelay: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "relay",
            abstract: "Relay standard input and output to the application this command line belongs to",
            discussion: """
                Connects to a socket the application listens on, by the name the application \
                gives, and copies bytes both ways until either side ends. The application \
                shows the whole command to run when it has one to ask for.
                """,
            shouldDisplay: false
        )

        @Argument(help: "The socket's name, as the application gave it")
        var name: String

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            guard let group = ServiceIdentity.appGroup,
                let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            else {
                throw ContainerizationError(.unsupported, message: "this command line does not belong to an application, so there is nothing to relay to")
            }
            let socket = try StreamRelay.connect(name: name, in: folder.path(percentEncoded: false))
            defer { close(socket) }
            StreamRelay.run(input: FileHandle.standardInput.fileDescriptor, output: FileHandle.standardOutput.fileDescriptor, socket: socket)
        }
    }
}

/// Copies bytes both ways between a pair of descriptors and a connected socket.
enum StreamRelay {
    /// A socket name is one path component that ends in `.sock`: the folder is not the
    /// caller's to choose.
    static func nameValid(_ name: String) -> Bool {
        let allowed = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_")
        }
        return allowed && name.hasSuffix(".sock") && name.count > ".sock".count && !name.hasPrefix(".")
    }

    /// Connect to the socket `name` in `directory`.
    ///
    /// The socket is named from inside its folder: a socket address holds 104 bytes, and
    /// the path of a group container uses most of them. This process is the command and
    /// nothing else, so changing its directory disturbs nobody.
    static func connect(name: String, in directory: String) throws -> Int32 {
        guard nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "'\(name)' is not a socket name: letters, digits, '.', '-' and '_', ending in .sock")
        }
        guard chdir(directory) == 0 else {
            throw ContainerizationError(.internalError, message: "the application's folder could not be entered: \(String(cString: strerror(errno)))")
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ContainerizationError(.internalError, message: "a socket could not be made: \(String(cString: strerror(errno)))")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in name.utf8.enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            if code == ENOENT || code == ECONNREFUSED {
                throw ContainerizationError(
                    .notFound,
                    message: "the application is not waiting for this command. Open the window that showed it, and run it again while that window is open")
            }
            throw ContainerizationError(.internalError, message: "the application could not be reached: \(String(cString: strerror(code)))")
        }
        return descriptor
    }

    /// Copy `input` to the socket and the socket to `output`, until the far end of the
    /// socket closes. The end of `input` is passed on as the end of what this side sends,
    /// and what the far end still has to say is copied out before returning.
    ///
    /// The sending worker is stopped and joined before the caller takes its descriptors
    /// back. Idle input and a full socket are polled so peer closure can stop that worker.
    static func run(input: Int32, output: Int32, socket: Int32) {
        // A reader that has gone away is an end like any other, not a signal to die on.
        signal(SIGPIPE, SIG_IGN)
        // Darwin's Unix-domain send can block under backpressure with MSG_DONTWAIT
        // alone. Borrow the socket in nonblocking mode, restoring its flags on return.
        let flags = fcntl(socket, F_GETFL)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        defer { _ = fcntl(socket, F_SETFL, flags) }
        let ownership = SocketOwnership()
        let sent = DispatchSemaphore(value: 0)
        let sending = Thread {
            defer { sent.signal() }
            copyInput(from: input, to: socket, ownership: ownership)
            ownership.whileOwned { shutdown(socket, SHUT_WR) }
        }
        sending.start()
        copy(from: socket, to: output)
        ownership.release()
        sent.wait()
    }

    /// Whether the relay still owns its socket; the caller takes it back when `run` returns.
    private final class SocketOwnership: Sendable {
        private let owned = Mutex(true)

        var isOwned: Bool { owned.withLock { $0 } }

        func whileOwned(_ body: () -> Void) {
            owned.withLock { if $0 { body() } }
        }

        func release() {
            owned.withLock { $0 = false }
        }
    }

    /// The relay is the sole reader of input. A ready pipe can be read without waiting;
    /// socket sends are nonblocking, so backpressure never holds the ownership handoff.
    private static func copyInput(from input: Int32, to socket: Int32, ownership: SocketOwnership) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while waitFor(input, events: Int16(POLLIN), ownership: ownership) {
            let count = read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            var written = 0
            while written < count, ownership.isOwned {
                let result = buffer.withUnsafeBytes { send(socket, $0.baseAddress! + written, count - written, 0) }
                if result < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        guard waitFor(socket, events: Int16(POLLOUT), ownership: ownership) else { return }
                        continue
                    }
                    return
                }
                guard result > 0 else { return }
                written += result
            }
        }
    }

    private static func waitFor(_ descriptor: Int32, events: Int16, ownership: SocketOwnership) -> Bool {
        guard descriptor >= 0 else { return false }
        while ownership.isOwned {
            var waiting = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&waiting, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready > 0 {
                guard waiting.revents & Int16(POLLNVAL) == 0 else { return false }
                return ownership.isOwned
            }
        }
        return false
    }

    /// Copy until the source ends or the destination refuses more.
    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var waiting = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
                if poll(&waiting, 1, -1) < 0 && errno != EINTR { return }
                continue
            }
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + written, count - written) }
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return }
                written += result
            }
        }
    }
}
