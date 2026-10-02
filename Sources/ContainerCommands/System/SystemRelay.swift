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
    static func run(input: Int32, output: Int32, socket: Int32) {
        // A reader that has gone away is an end like any other, not a signal to die on.
        signal(SIGPIPE, SIG_IGN)
        let sending = Thread {
            copy(from: input, to: socket)
            shutdown(socket, SHUT_WR)
        }
        sending.start()
        copy(from: socket, to: output)
    }

    /// Copy until the source ends or the destination refuses more.
    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
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
