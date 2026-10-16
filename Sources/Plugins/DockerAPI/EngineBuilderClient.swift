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

import ContainerBuild
import ContainerImagesServiceClient
import ContainerizationError
import Darwin
import DockerAPIService
import Foundation
import GRPCCore
import Logging
import TerminalProgress

/// `POST /build`'s engine: `container build`'s pipeline, in this process. The builder is
/// started when it needs it, BuildKit's output is read from a pipe as plain text, and the
/// image is loaded, unpacked for the host and tagged as `container build` leaves it.
///
/// The context is a directory this service unpacked, so nothing is borrowed for it.
struct EngineBuilderClient: EngineBuilder {
    let log: Logger

    func build(_ request: DockerBuildRequest, output: @escaping @Sendable (Data) async -> Void) async throws {
        let system = try await EngineContainersClient.systemConfig()
        let pipe = try BuildOutputPipe()
        let relay = Task { await pipe.relay(to: output) }
        // Each change of what the builder is doing, as a line: starting the builder can take a
        // minute, and a client with nothing to show looks hung.
        let progress = ProgressLines(output: output)
        do {
            _ = try await Builder.build(
                Builder.BuildRequest(
                    contextDir: request.context.path(percentEncoded: false),
                    tags: request.tags,
                    buildArgs: request.buildArgs,
                    labels: request.labels,
                    target: request.target,
                    platforms: request.platform.map { [$0] } ?? [],
                    noCache: request.noCache,
                    pull: request.pull
                ),
                dockerfile: request.dockerfile,
                dockerignore: request.dockerignore,
                terminal: nil,
                output: pipe.writer,
                registryCredentials: request.credentials.mapValues(EngineImagesClient.engineCredential),
                containerSystemConfig: system,
                log: log,
                progressUpdate: { events in await progress.report(events) }
            )
        } catch {
            pipe.closeWriter()
            await relay.value
            throw Self.translated(error)
        }
        pipe.closeWriter()
        await relay.value
    }

    /// A failure in the words the client shows: a `ContainerizationError`'s message, not its
    /// type, BuildKit's own words for a build that failed (`failed to solve: …`) without the
    /// RPC status in front, and a refused input as a 400.
    static func translated(_ error: any Error) -> any Error {
        switch error {
        case let error as RPCError:
            return DockerAPIError.internalError(error.message)
        case let error as BuildInputError:
            return DockerAPIError.badRequest(error.message)
        case let error as ContainerizationError:
            let cause = error.cause.map { ": \($0)" } ?? ""
            return DockerAPIError(error.isCode(.invalidArgument) ? .badRequest : .internalServerError, error.message + cause)
        default:
            return error
        }
    }
}

/// The builder's progress descriptions as output lines, each once.
actor ProgressLines {
    let output: @Sendable (Data) async -> Void
    private var last: String?

    init(output: @escaping @Sendable (Data) async -> Void) {
        self.output = output
    }

    func report(_ events: [ProgressUpdateEvent]) async {
        for event in events {
            guard case .setDescription(let text) = event, !text.isEmpty, text != last else { continue }
            last = text
            await output(Data((text + "\n").utf8))
        }
    }
}

/// A pipe BuildKit's output is written into and read back from.
///
/// The build writes from an actor without waiting on anyone, so the pipe is read on a thread of
/// its own, as fast as it fills, into a bounded buffer: a client that reads slowly loses
/// output past the bound rather than stalling the build. The write end never raises `SIGPIPE`,
/// should the read end be gone first.
final class BuildOutputPipe: Sendable {
    /// What is held for the client before newer output is dropped.
    static let bufferedChunks = 1024
    static let chunkSize = 1 << 16

    let writer: FileHandle
    private let readFD: Int32

    init() throws {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        readFD = fds[0]
        writer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    }

    /// Ends the output: the reader sees the end once what was written is read.
    func closeWriter() {
        try? writer.close()
    }

    /// Reads until the write end closes, handing each piece to `output`, then closes the read
    /// end.
    func relay(to output: @escaping @Sendable (Data) async -> Void) async {
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(Self.bufferedChunks))
        let fd = readFD
        let thread = Thread {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkSize, alignment: 1)
            defer {
                buffer.deallocate()
                close(fd)
                continuation.finish()
            }
            while true {
                let count = read(fd, buffer, Self.chunkSize)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                continuation.yield(Data(bytes: buffer, count: count))
            }
        }
        thread.name = "docker-build-output"
        thread.start()
        for await chunk in chunks {
            await output(chunk)
        }
    }
}
