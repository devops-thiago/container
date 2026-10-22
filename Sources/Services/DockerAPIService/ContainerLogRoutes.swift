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
import Darwin
import Foundation
import NIOCore

/// A cursor over the engine's log file for a container.
///
/// The engine keeps one bounded file per container. When it is full the engine rewrites it from
/// the start, in place, with a header line of its own, so a reader holding the descriptor sees
/// either a file shorter than where it was or a different first few bytes: either way it starts
/// again from the top, as the `container logs` command does.
struct DockerLogFile {
    static let chunkSize = 64 << 10
    private static let headSize = 128

    let fd: Int32
    private(set) var offset: UInt64 = 0
    private var head = Data()

    init(fd: Int32) throws {
        self.fd = fd
        head = try readHead()
    }

    /// Starts from where `tail` lines from the end begin: `nil` for the whole file, 0 for its
    /// end. A last line without its newline counts as a line. At most `maxBytes` before the end
    /// are looked through.
    mutating func seek(tail lines: Int?, maxBytes: Int = 16 << 20) throws {
        let size = try self.size()
        guard let lines else {
            offset = 0
            return
        }
        guard lines > 0 else {
            offset = size
            return
        }
        // Newlines seen from the end. The one that ends the file ends the last line rather than
        // starting another.
        var seen = 0
        var position = size
        let floor = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while position > floor {
            let count = Int(min(UInt64(Self.chunkSize), position - floor))
            position -= UInt64(count)
            let read = pread(fd, &buffer, count, off_t(position))
            guard read == count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for index in stride(from: count - 1, through: 0, by: -1) where buffer[index] == UInt8(ascii: "\n") {
                let at = position + UInt64(index)
                if at == size - 1 { continue }
                seen += 1
                if seen == lines {
                    offset = at + 1
                    return
                }
            }
        }
        offset = floor
    }

    /// What has been written since the last read, at most `chunkSize`; empty when there is
    /// nothing new.
    mutating func next() throws -> Data {
        let size = try self.size()
        let newHead = try readHead()
        if size < offset || !newHead.starts(with: head) {
            // Rewritten from the start since the last look.
            offset = 0
        }
        head = newHead
        guard size > offset else { return Data() }
        let count = Int(min(UInt64(Self.chunkSize), size - offset))
        var bytes = [UInt8](repeating: 0, count: count)
        let read = pread(fd, &bytes, count, off_t(offset))
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += UInt64(read)
        return Data(bytes.prefix(read))
    }

    /// The file was rewritten from the start since the last read: the engine's rollover of a
    /// full log, or the start of the container's next run.
    func isRewritten() throws -> Bool {
        let headChanged = try !readHead().starts(with: head)
        return try size() < offset || headChanged
    }

    /// The file has no name left: its container was deleted.
    func isDeleted() throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_nlink == 0
    }

    func size() throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(info.st_size)
    }

    private func readHead() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.headSize)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(bytes.prefix(count))
    }
}

/// Turns log bytes into what `logs` sends: framed for a container without a tty, raw for one
/// with, each line stamped with when it was read when `timestamps` asks for it.
struct DockerLogFramer {
    let multiplexed: Bool
    let stream: StdStream
    let timestamps: Bool
    private var atLineStart = true

    init(multiplexed: Bool, stream: StdStream, timestamps: Bool) {
        self.multiplexed = multiplexed
        self.stream = stream
        self.timestamps = timestamps
    }

    /// dockerd's `RFC3339Nano` stamp with its fixed nine digits, so stamps line up.
    static func stamp(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let nanos = min(max(Int(((date.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)), 0), 999_999_999)
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%09dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min,
            parts.tm_sec, nanos)
    }

    mutating func frame(_ data: Data, at time: Date) -> ByteBuffer {
        var payload = ByteBuffer()
        if timestamps {
            let stamp = Self.stamp(time) + " "
            for byte in data {
                if atLineStart {
                    payload.writeString(stamp)
                    atLineStart = false
                }
                payload.writeInteger(byte)
                if byte == UInt8(ascii: "\n") { atLineStart = true }
            }
        } else {
            payload.writeBytes(data)
        }
        return multiplexed ? StdMultiplexer.frame(payload, stream: stream) : payload
    }
}

/// `GET /containers/{id}/logs`.
extension ContainerToolRoutes.Routes {
    /// `?follow=&stdout=&stderr=&tail=&timestamps=&since=`, from the engine's log file.
    ///
    /// The engine keeps stdout and stderr together, untagged, so everything is sent as stdout,
    /// or as stderr when only stderr is asked for. `timestamps` stamps each line with when this
    /// service read it, not when it was written. `since` and `until` are accepted and ignored:
    /// the file has no times to filter by. `follow` looks at the file for new output until the
    /// container's run ends (it stops, restarts or is deleted) and its last output is sent, or
    /// the client leaves.
    func logs(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let stdout = try request.bool("stdout")
        let stderr = try request.bool("stderr")
        guard stdout || stderr else {
            throw DockerAPIError.badRequest("must specify at least one of 'stdout' or 'stderr'")
        }
        let follow = try request.bool("follow")
        let timestamps = try request.bool("timestamps")
        // dockerd reads anything that is not a number as "all".
        let tail = request.query("tail").flatMap { Int($0) }.flatMap { $0 < 0 ? nil : $0 }
        let container = try await find(reference)
        let handle = try await engine.log(container.snapshot)
        let start: DockerLogFile
        // Without follow, what is there now and no more: a container writing faster than the
        // client reads would otherwise keep the answer going.
        let end: UInt64?
        do {
            var file = try DockerLogFile(fd: handle.fileDescriptor)
            try file.seek(tail: tail)
            start = file
            end = follow ? nil : try file.size()
        } catch {
            try? handle.close()
            throw DockerAPIError.internalError("could not read the container's log: \(error)")
        }
        let multiplexed = !container.snapshot.configuration.initProcess.terminal
        let initialFramer = DockerLogFramer(multiplexed: multiplexed, stream: stdout ? .stdout : .stderr, timestamps: timestamps)
        let engine = self.engine
        let options = self.options
        let run = container.snapshot
        let contentType = multiplexed ? "application/vnd.docker.multiplexed-stream" : "application/vnd.docker.raw-stream"
        return .stream(status: .ok, contentType: contentType) { writer in
            defer { try? handle.close() }
            try await DockerLogPump.run(
                file: start, end: end, framer: initialFramer, options: options, stillRunning: { try await Self.stillInRun(engine, run) },
                write: { try await writer.write($0) })
        }
    }

    /// Whether the container is still in the run `run` was taken in. dockerd closes a
    /// container's log at every exit, a restart's included, and a follower ends there; so does
    /// this one, and a container that is not running is not followed at all.
    static func stillInRun(_ engine: Engine, _ run: ContainerSnapshot) async throws -> Bool {
        guard let snapshot = try await engine.get(run.id) else { return false }
        return snapshot.isInRun(of: run)
    }
}

/// Sends a container's log file on, framed, as `logs` and an output-only `attach` do.
enum DockerLogPump {
    /// Writes what the file holds from where `file` is: up to `end` when it is given, else on
    /// and on, looking for new output every `logPollInterval`, until the container's run has
    /// ended (`stillRunning`, asked every `logStatusInterval` and when the file is rewritten
    /// from the start, or the file deleted with the container) and its last output is sent, or
    /// `write` or `present` says the client is gone. A file rewritten by the next run's start
    /// is not sent.
    static func run(
        file start: DockerLogFile, end: UInt64?, framer initialFramer: DockerLogFramer, options: DockerToolOptions,
        stillRunning: () async throws -> Bool, present: () async -> Bool = { true }, write: (ByteBuffer) async throws -> Void
    ) async throws {
        var file = start
        var framer = initialFramer
        let follow = end == nil
        var stopped = !follow
        var lastLook = ContinuousClock.now
        if follow, try await !stillRunning() {
            stopped = true
        }
        while true {
            if let end, file.offset >= end { return }
            if follow, try file.isRewritten() {
                // The engine's rollover goes on being sent; the next run's start does not.
                if !stopped {
                    lastLook = .now
                    stopped = try await !stillRunning()
                }
                if stopped { return }
            }
            let chunk = try file.next()
            if !chunk.isEmpty {
                try await write(framer.frame(chunk, at: options.now()))
                continue
            }
            // Everything there is has been sent: the last read after a stop has been made.
            if stopped { return }
            try await Task.sleep(for: options.logPollInterval)
            if try file.isDeleted() {
                // Deleted with its container: one more read, for what is left in it.
                stopped = true
            } else if lastLook.duration(to: .now) >= options.logStatusInterval {
                lastLook = .now
                // A client that went away while the container was quiet has nothing to read.
                if await !present() { return }
                // One more read after the stop, for what the container wrote last.
                stopped = try await !stillRunning()
            }
        }
    }
}
