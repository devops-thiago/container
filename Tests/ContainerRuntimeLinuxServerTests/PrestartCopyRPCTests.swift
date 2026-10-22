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

import Containerization
import ContainerizationArchive
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import NIOPosix
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct PrestartCopyRPCTests {
    typealias Request = Com_Apple_Containerization_Sandbox_V3_CopyRequest
    typealias Response = Com_Apple_Containerization_Sandbox_V3_CopyResponse

    final class Receiver: RegistrableRPCService, Sendable {
        let requests: Mutex<[Request]>

        init() { requests = Mutex([]) }

        func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
            router.registerHandler(
                forMethod: Com_Apple_Containerization_Sandbox_V3_SandboxContext.Method.Copy.descriptor,
                deserializer: ProtobufDeserializer<Request>(), serializer: ProtobufSerializer<Response>()
            ) { stream, _ in
                let request = try await ServerRequest(stream: stream)
                self.requests.withLock { $0.append(request.message) }
                return StreamingServerResponse(single: ServerResponse(message: Response.with { $0.status = .complete }, metadata: [:]))
            }
        }
    }

    // Exercise the real Vminitd serializer, not a fake GuestCopyAgent above the broken call.
    @Test("every copy in goes to the agent as an archive, a file's too", .timeLimit(.minutes(1)))
    func archiveFlagOnWire() async throws {
        let receiver = Receiver()
        try await withGRPCServer(
            transport: .http2NIOPosix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext),
            services: [receiver]
        ) { server in
            let address = try #require(try await server.listeningAddress?.ipv4)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            #expect(fd >= 0)
            var peer = sockaddr_in()
            peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            peer.sin_family = sa_family_t(AF_INET)
            peer.sin_port = UInt16(address.port).bigEndian
            peer.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == 0 else {
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let agent = try await Vminitd(connection: FileHandle(fileDescriptor: fd, closeOnDealloc: false), group: MultiThreadedEventLoopGroup.singleton)
            do {
                try await VminitdCopyAgent.requestCopy(
                    agent: agent, root: "/run/container/test/rootfs", path: "/smoke", port: 12345, mode: 0o640, createParents: true)
            } catch {
                try? await agent.close()
                throw error
            }
            try await agent.close()
            let requests = receiver.requests.withLock { $0 }
            #expect(requests.map(\.isArchive) == [true])
            for request in requests {
                #expect(request.direction == .copyIn)
                #expect(request.root == "/run/container/test/rootfs")
                #expect(request.path == "/smoke")
                #expect(request.vsockPort == 12345)
                #expect(request.mode == 0o640)
                #expect(request.createParents)
            }
        }
    }

    @Test("a file is unpacked in its destination's parent, as the one entry named for it")
    func fileUnpackPoint() {
        #expect(VminitdCopyAgent.unpackPoint(for: "/etc/app/config", isDirectory: false) == ("/etc/app", "config"))
        #expect(VminitdCopyAgent.unpackPoint(for: "/motd", isDirectory: false) == ("/", "motd"))
        #expect(VminitdCopyAgent.unpackPoint(for: "/srv/smoke", isDirectory: true) == ("/srv/smoke", "."))
    }

    @Test("a file goes as one archive entry with its bytes, its mode and its host owner")
    func fileArchivePayload() async throws {
        let source = try PrestartCopyTests.Source()
        let expected = Data([0x1f, 0x8b, 0x08, 0, 0, 1, 2, 3])
        try expected.write(to: source.file)
        let archive = source.top.appending(path: "payload.tar.gz")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        try await VminitdCopyAgent.send(
            source.file, isDirectory: false, name: "config", mode: 0o640, owner: nil, to: FileHandle(forWritingTo: archive))
        let entries = Array(try ArchiveReader(format: .pax, filter: .gzip, file: archive))
        try #require(entries.count == 1)
        let (entry, data) = entries[0]
        #expect(entry.path == "config")
        #expect(entry.fileType == .regular)
        #expect(entry.permissions & 0o7777 == 0o640)
        #expect(data == expected)
        var info = stat()
        #expect(stat(source.file.path, &info) == 0)
        #expect(entry.owner == info.st_uid)
        #expect(entry.group == info.st_gid)
    }

    @Test("a file's archive is stored, not compressed: a copy costs what sending its bytes did")
    func fileArchiveIsStored() async throws {
        let source = try PrestartCopyTests.Source()
        try Data(count: 1 << 20).write(to: source.file)
        let archive = source.top.appending(path: "stored.tar.gz")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        try await VminitdCopyAgent.send(source.file, isDirectory: false, name: "zeros", mode: 0, owner: nil, to: FileHandle(forWritingTo: archive))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int)
        #expect(size > 1 << 20, "a megabyte of zeros compressed to \(size) bytes")
        let entries = Array(try ArchiveReader(format: .pax, filter: .gzip, file: archive))
        #expect(entries.map(\.1) == [Data(count: 1 << 20)])
    }

    @Test("directory payloads contain nested files and their contents")
    func nestedDirectoryPayload() async throws {
        let source = try PrestartCopyTests.Source()
        let nested = source.directory.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested contents\n".utf8).write(to: nested.appending(path: "hello.txt"))
        let archive = source.top.appending(path: "payload.tar.gz")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        try await VminitdCopyAgent.send(source.directory, isDirectory: true, name: ".", mode: 0, owner: nil, to: FileHandle(forWritingTo: archive))
        let extracted = source.top.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", extracted.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        #expect(try String(contentsOf: extracted.appending(path: "nested/hello.txt"), encoding: .utf8) == "nested contents\n")
    }
}
