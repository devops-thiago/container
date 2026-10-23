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

import ContainerLog
import ContainerResource
import Darwin
import Foundation
import NIOCore

/// A cursor over the engine's log file for a container: `container logs`'s own.
///
/// The engine keeps one bounded file per container. When it is full the engine rewrites it from
/// the start, in place, with a header line of its own, so a reader holding the descriptor sees
/// either a file shorter than where it was or a different first few bytes: either way it starts
/// again from the top, as the `container logs` command does.
typealias DockerLogFile = LogFileReader

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
        let engine = self.engine
        let handle = try await engine.log(container.snapshot)
        let run: ContainerSnapshot?
        let start: DockerLogFile
        // Without follow, what is there now and no more: a container writing faster than the
        // client reads would otherwise keep the answer going.
        let end: UInt64?
        do {
            // Placed on the log within the run it follows, so the next run's log is never sent
            // as this one's.
            (run, start) = try await ContainerSnapshot.startFollowing(
                follow ? container.snapshot : nil, look: { try await engine.get(container.snapshot.id) }
            ) {
                try DockerLogPump.readingLog {
                    var file = try DockerLogFile(fd: handle.fileDescriptor)
                    try file.seek(tail: tail)
                    return file
                }
            }
            end = follow ? nil : try DockerLogPump.readingLog { try start.size() }
        } catch {
            try? handle.close()
            throw error
        }
        let multiplexed = !container.snapshot.configuration.initProcess.terminal
        let initialFramer = DockerLogFramer(multiplexed: multiplexed, stream: stdout ? .stdout : .stderr, timestamps: timestamps)
        let options = self.options
        let contentType = multiplexed ? "application/vnd.docker.multiplexed-stream" : "application/vnd.docker.raw-stream"
        return .stream(status: .ok, contentType: contentType) { writer in
            defer { try? handle.close() }
            try await DockerLogPump.run(
                file: start, end: end, framer: initialFramer, options: options,
                stillRunning: {
                    guard let run else { return false }
                    return try await Self.stillInRun(engine, run)
                },
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
    /// `body`, with a failure to read the log said as the 500 it is.
    static func readingLog<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw DockerAPIError.internalError("could not read the container's log: \(error)")
        }
    }

    /// Writes what the file holds from where `file` is: up to `end` when it is given, else on
    /// and on, looking for new output every `logPollInterval`, until the container's run has
    /// ended (`stillRunning`, asked every `logStatusInterval` and when the file is rewritten
    /// from the start, or the file deleted with the container) and its last output is sent, or
    /// `write` or `present` says the client is gone. A rewrite from the start is sent on or not
    /// as `LogRollover.readsRewrite` says: the engine's rollover is the run's, sent even after
    /// the run has ended; the next run's start is not.
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
            let chunk: Data
            if follow {
                let next = try await file.next { rolledOver in
                    try await LogRollover.readsRewrite(rolledOver: rolledOver, ended: &stopped) {
                        lastLook = .now
                        return try await !stillRunning()
                    }
                }
                // Rewritten by the next run's start: none of it is the run's.
                guard let next else { return }
                chunk = next
            } else {
                chunk = try file.next()
            }
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
