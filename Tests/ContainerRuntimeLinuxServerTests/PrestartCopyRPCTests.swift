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
        let rejection: RPCError?

        init(rejection: RPCError? = nil) {
            requests = Mutex([])
            self.rejection = rejection
        }

        func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
            router.registerHandler(
                forMethod: Com_Apple_Containerization_Sandbox_V3_SandboxContext.Method.Copy.descriptor,
                deserializer: ProtobufDeserializer<Request>(), serializer: ProtobufSerializer<Response>()
            ) { stream, _ in
                let request = try await ServerRequest(stream: stream)
                self.requests.withLock { $0.append(request.message) }
                if let rejection = self.rejection { throw rejection }
                return StreamingServerResponse(single: ServerResponse(message: Response.with { $0.status = .complete }, metadata: [:]))
            }
        }
    }

    // Exercise the real Vminitd serializer, not a fake GuestCopyAgent above the broken call.
    @Test("files use the owned raw operation; directories still use archives", .timeLimit(.minutes(1)))
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
                    agent: agent, root: "/run/container/test/rootfs", path: "/smoke", port: 12345, mode: 0o640, createParents: true,
                    isDirectory: true, owner: nil)
                try await VminitdCopyAgent.requestCopy(
                    agent: agent, root: "/run/container/test/rootfs", path: "/smoke", port: 12345, mode: 0o640, createParents: true,
                    isDirectory: false, owner: CopyOwner(uid: 1234, gid: 5678))
                try await VminitdCopyAgent.requestCopy(
                    agent: agent, root: "/run/container/test/rootfs", path: "/smoke", port: 12345, mode: 0o640, createParents: true,
                    isDirectory: true, owner: nil, noOverwriteDirNonDir: true)
            } catch {
                try? await agent.close()
                throw error
            }
            try await agent.close()
            let requests = receiver.requests.withLock { $0 }
            #expect(requests.map(\.isArchive) == [true, false, true])
            #expect(requests.map(\.direction) == [.copyIn, .copyInOwnedFile, .copyInCheckedArchive])
            #expect(requests.map(\.hasOwnerUid) == [false, true, false])
            #expect(requests.map(\.hasOwnerGid) == [false, true, false])
            #expect(requests[1].ownerUid == 1234)
            #expect(requests[1].ownerGid == 5678)
            for request in requests {
                #expect(request.root == "/run/container/test/rootfs")
                #expect(request.path == "/smoke")
                #expect(request.vsockPort == 12345)
                #expect(request.mode == 0o640)
                #expect(request.createParents)
            }
        }
    }

    @Test("old guests fail closed with upgrade guidance and other errors remain intact", .timeLimit(.minutes(1)), arguments: [true, false])
    func legacyGuestRejection(legacy: Bool) async throws {
        let rejection = RPCError(code: .invalidArgument, message: legacy ? "copy: unrecognized direction 2" : "copy: invalid root")
        let receiver = Receiver(rejection: rejection)
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
                    agent: agent, root: "/rootfs", path: "/file", port: 12345, mode: 0o640, createParents: false,
                    isDirectory: false, owner: CopyOwner(uid: 1, gid: 2))
                Issue.record("old guest accepted a copy")
            } catch {
                let message = String(describing: error)
                if legacy {
                    #expect(message.contains("container system upgrade-guest"))
                    #expect(message.contains("preserves workload data"))
                } else {
                    #expect((error as? RPCError)?.message == rejection.message)
                }
            }
            try await agent.close()
            #expect(receiver.requests.withLock { $0.count } == 1, "never retry with the unsafe legacy operation")
        }
    }

    @Test("single-file owners preserve recorded identity and explicit overrides")
    func fileOwnerSelection() throws {
        let source = try PrestartCopyTests.Source()
        var info = stat()
        #expect(stat(source.file.path, &info) == 0)
        #expect(try VminitdCopyAgent.fileOwner(source.file, override: nil) == CopyOwner(uid: info.st_uid, gid: info.st_gid))
        try CopyOwner.record(CopyOwner(uid: 2345, gid: 3456), at: source.file.path)
        #expect(try VminitdCopyAgent.fileOwner(source.file, override: nil) == CopyOwner(uid: 2345, gid: 3456))
        #expect(try VminitdCopyAgent.fileOwner(source.file, override: CopyOwner(uid: 0, gid: 0)) == CopyOwner(uid: 0, gid: 0))
    }

    @Test("single-file payloads are exact bytes, even when they begin with a gzip header")
    func fileArchivePayload() async throws {
        let source = try PrestartCopyTests.Source()
        let expected = Data([0x1f, 0x8b, 0x08, 0, 0, 1, 2, 3])
        try expected.write(to: source.file)
        let payload = source.top.appending(path: "payload")
        FileManager.default.createFile(atPath: payload.path, contents: nil)
        try await VminitdCopyAgent.send(
            source.file, isDirectory: false, name: "config", mode: 0o640, owner: nil, to: FileHandle(forWritingTo: payload))
        #expect(try Data(contentsOf: payload) == expected)
    }

    @Test("a large single-file transfer preserves the exact length and contents")
    func fileArchiveIsStored() async throws {
        let source = try PrestartCopyTests.Source()
        let expected = Data(count: 1 << 20)
        try expected.write(to: source.file)
        let payload = source.top.appending(path: "payload")
        FileManager.default.createFile(atPath: payload.path, contents: nil)
        try await VminitdCopyAgent.send(source.file, isDirectory: false, name: "zeros", mode: 0, owner: nil, to: FileHandle(forWritingTo: payload))
        #expect(try Data(contentsOf: payload) == expected)
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
