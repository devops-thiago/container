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
import Foundation
import Logging
import NIOHTTP1
import Synchronization
import TerminalProgress
import Testing

@testable import ContainerAPIClient

/// Offsets are asserted exactly only where the server held its connection until the client had
/// written everything sent (`.hold`). A connection that simply goes quiet or hangs up races the
/// downloader's reader, and on a busy machine how much had been kept by then is anyone's guess,
/// so the tests about silence assert what must be true however that race went.
@Suite(.serialized)
struct FileDownloaderTests {
    /// Long enough that only a scripted silence can run it out.
    private static let patient = Duration.seconds(30)
    /// The idle timeout of the tests whose subject is silence.
    private static let impatient = Duration.milliseconds(300)

    private static func policy(idle: Duration = patient, fruitless: Int = 3, attempts: Int = 20) -> FileDownloader.Policy {
        FileDownloader.Policy(
            idleTimeout: idle,
            connectTimeout: .seconds(30),
            responseTimeout: .seconds(30),
            fruitlessAttemptLimit: fruitless,
            attemptLimit: attempts,
            initialBackoff: .milliseconds(5),
            maximumBackoff: .milliseconds(20))
    }

    private static func payload(_ count: Int = 100_000, seed: UInt8 = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
    }

    /// What a progress handler was told, reduced to what a progress bar would show.
    private final class Progress: Sendable {
        private struct State: Sendable {
            var total: Int64 = 0
            var sizes: [Int64] = []
            var notes: [String] = []
        }
        private let state = Mutex(State())

        var handler: ProgressUpdateHandler {
            { events in
                self.state.withLock { state in
                    for event in events {
                        switch event {
                        case .addTotalSize(let bytes): state.total += bytes
                        case .setSize(let bytes): state.sizes.append(bytes)
                        case .setSubDescription(let note): state.notes.append(note)
                        default: break
                        }
                    }
                }
            }
        }
        var total: Int64 { state.withLock { $0.total } }
        var sizes: [Int64] { state.withLock { $0.sizes } }
        var notes: [String] { state.withLock { $0.notes } }
    }

    private struct Outcome {
        let file: [UInt8]?
        let error: (any Error)?
        let seen: [FlakyFileServer.Seen]
        let progress: Progress
        let log: [String]
    }

    private func download(
        _ payload: [UInt8],
        script: [FlakyFileServer.Reply],
        policy: FileDownloader.Policy = Self.policy(),
        existing: [UInt8]? = nil
    ) async throws -> Outcome {
        let server = try FlakyFileServer(serving: payload, script: script)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-downloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.bin")
        if let existing { try Data(existing).write(to: destination) }

        // Hangs up a held connection once everything sent on it is on disk.
        let releasing = Task {
            while !Task.isCancelled {
                if let offset = server.heldOffset {
                    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                    if size >= offset { server.releaseHeld() }
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let progress = Progress()
        let lines = CapturedLog()
        var failure: (any Error)?
        do {
            try await FileDownloader.downloadFile(
                url: server.url, to: destination, progressUpdate: progress.handler, policy: policy,
                log: Logger(label: "file-downloader-test") { _ in CapturingLogHandler(lines: lines) })
        } catch {
            failure = error
        }
        releasing.cancel()
        await server.shutdown()
        return Outcome(
            file: (try? Data(contentsOf: destination)).map { [UInt8]($0) },
            error: failure, seen: server.seen, progress: progress, log: lines.all)
    }

    @Test("a download that meets no trouble is one request and the whole file")
    func downloadsTheWholeFile() async throws {
        let payload = Self.payload()
        let outcome = try await download(payload, script: [.init()])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen == [.init(range: nil, ifRange: nil)])
        #expect(outcome.progress.total == Int64(payload.count))
        #expect(outcome.progress.sizes.last == Int64(payload.count))
        #expect(outcome.progress.notes.isEmpty)
    }

    @Test("what was at the destination is replaced, not continued")
    func replacesWhatWasAtTheDestination() async throws {
        let payload = Self.payload(10_000)
        let outcome = try await download(payload, script: [.init()], existing: Self.payload(50_000, seed: 9))

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen == [.init(range: nil, ifRange: nil)])
    }

    @Test("a lost connection is followed by a request for the rest of the file, not all of it")
    func resumesFromTheBytesOnDisk() async throws {
        let payload = Self.payload()
        let outcome = try await download(payload, script: [.init(send: 40_000, ending: .hold), .init()])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen == [.init(range: nil, ifRange: nil), .init(range: "bytes=40000-", ifRange: "\"v1\"")])
        // The size is announced once: a resumed response carries the length of what is left,
        // and adding that to the total would leave the bar short of the end for good.
        #expect(outcome.progress.total == Int64(payload.count))
        #expect(outcome.progress.sizes.last == Int64(payload.count))
        #expect(outcome.progress.sizes == outcome.progress.sizes.sorted(), "a resumed transfer never moves the bar back")
        #expect(outcome.progress.notes.count == 2)
        #expect(outcome.progress.notes.first?.hasPrefix("the connection was lost") == true)
        #expect(outcome.progress.notes.first?.hasSuffix(", retrying") == true)
        #expect(outcome.progress.notes.last == "", "the note goes when data arrives again")
    }

    @Test("a connection that goes silent is abandoned, and the transfer carries on from what it kept")
    func abandonsASilentConnection() async throws {
        // No response ever carries more than part of the file before going quiet, so the only
        // way to the end is to notice the silence and ask for the rest, more than once.
        let payload = Self.payload()
        let outcome = try await download(
            payload, script: [.init(send: 40_000, ending: .stall)], policy: Self.policy(idle: Self.impatient, fruitless: 10, attempts: 60))

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.first == .init(range: nil, ifRange: nil))
        let ranged = outcome.seen.filter { $0.range != nil }
        #expect(ranged.count >= 2)
        for request in ranged {
            #expect(request.ifRange == "\"v1\"")
            let from = request.range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
            #expect(from > 0 && from < payload.count, "\(request)")
        }
        #expect(outcome.progress.total == Int64(payload.count))
        #expect(outcome.progress.sizes.last == Int64(payload.count))
        #expect(outcome.progress.notes.contains("no data arrived for 0.3 seconds, retrying"))
        #expect(outcome.progress.notes.last == "")
    }

    @Test("the modification date stands in when the server has no strong entity tag")
    func resumesAgainstTheModificationDate() async throws {
        let date = "Mon, 22 Jun 2026 10:05:38 GMT"
        let payload = Self.payload()
        let outcome = try await download(
            payload,
            script: [
                .init(send: 40_000, ending: .hold, etag: "W/\"weak\"", lastModified: date),
                .init(etag: "W/\"weak\"", lastModified: date),
            ])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.last == .init(range: "bytes=40000-", ifRange: date))
    }

    @Test("a server without ranges is asked for the whole file again, and the file is not doubled")
    func startsOverWithoutRanges() async throws {
        let payload = Self.payload()
        let outcome = try await download(
            payload,
            script: [
                .init(honoursRange: false, advertisesRanges: false, send: 40_000, ending: .hold),
                .init(honoursRange: false, advertisesRanges: false),
            ])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen == [.init(range: nil, ifRange: nil), .init(range: nil, ifRange: nil)])
        #expect(outcome.progress.total == Int64(payload.count))
    }

    @Test("a server that offers ranges and then ignores one gets its whole answer written from the start")
    func startsOverWhenTheRangeIsIgnored() async throws {
        let payload = Self.payload()
        let outcome = try await download(payload, script: [.init(send: 40_000, ending: .hold), .init(honoursRange: false)])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.map(\.range) == [nil, "bytes=40000-"])
    }

    @Test("a file replaced on the server mid-transfer is fetched whole, never stitched from two versions")
    func startsOverWhenTheFileChanged() async throws {
        let replacement = Self.payload(60_000, seed: 7)
        let outcome = try await download(
            Self.payload(),
            script: [.init(send: 40_000, ending: .hold), .init(etag: "\"v2\"", payload: replacement)])

        #expect(outcome.error == nil)
        #expect(outcome.file == replacement)
        #expect(outcome.seen.last == .init(range: "bytes=40000-", ifRange: "\"v1\""))
        #expect(outcome.progress.total == Int64(replacement.count))
        #expect(outcome.progress.sizes.last == Int64(replacement.count))
    }

    @Test("a replacement that names no version is continued on its size alone, not refused for ever")
    func forgetsAVersionTheServerNoLongerNames() async throws {
        let replacement = Self.payload(60_000, seed: 7)
        let outcome = try await download(
            Self.payload(),
            script: [
                .init(send: 40_000, ending: .hold),
                .init(send: 40_000, ending: .hold, etag: nil, payload: replacement),
                .init(etag: nil),
            ])

        #expect(outcome.error == nil)
        #expect(outcome.file == replacement)
        #expect(
            outcome.seen == [
                .init(range: nil, ifRange: nil),
                .init(range: "bytes=40000-", ifRange: "\"v1\""),
                .init(range: "bytes=40000-", ifRange: nil),
            ])
    }

    @Test("a refused range discards the partial file and starts over")
    func startsOverWhenTheRangeIsRefused() async throws {
        let payload = Self.payload()
        let outcome = try await download(
            payload,
            script: [.init(send: 40_000, ending: .hold), .init(status: .rangeNotSatisfiable), .init()])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.map(\.range) == [nil, "bytes=40000-", nil])
    }

    @Test("a transfer that keeps advancing outlives the limit on attempts that add nothing")
    func keepsGoingWhileEveryAttemptAdds() async throws {
        let payload = Self.payload()
        let outcome = try await download(
            payload, script: [.init(send: 20_000, ending: .hold)], policy: Self.policy(fruitless: 2))

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.map(\.range) == [nil, "bytes=20000-", "bytes=40000-", "bytes=60000-", "bytes=80000-"])
    }

    @Test("a download always ends, even one that adds a little every time")
    func stopsAtTheAttemptLimit() async throws {
        let outcome = try await download(
            Self.payload(), script: [.init(send: 8_000, ending: .hold)], policy: Self.policy(attempts: 4))

        let error = try #require(outcome.error as? ContainerizationError)
        #expect(error.code == .timeout)
        #expect(error.message.hasPrefix("download interrupted: the connection was lost"))
        #expect(error.message.contains("it took 4 attempts without finishing"))
        #expect(error.message.contains("0.0 of 0.1 MB received"))
        #expect(outcome.seen.map(\.range) == [nil, "bytes=8000-", "bytes=16000-", "bytes=24000-"])
    }

    @Test("silence on every attempt ends as a stalled download, after the attempts the policy allows")
    func givesUpWhenNothingArrives() async throws {
        let outcome = try await download(
            Self.payload(), script: [.init(send: 0, ending: .stall)], policy: Self.policy(idle: Self.impatient))

        let error = try #require(outcome.error as? ContainerizationError)
        #expect(error.code == .timeout)
        #expect(error.message.hasPrefix("download stalled: no data arrived for 0.3 seconds"))
        #expect(error.message.contains("3 attempts in a row ended without receiving anything new"))
        #expect(error.message.contains("0.0 of 0.1 MB received"))
        #expect(error.message.hasSuffix("Check the network connection and any VPN, proxy or content filter, then try again."))
        #expect(outcome.seen.count == 3)
    }

    @Test("a stall after part of the file says how far it got")
    func givesUpPartWayThrough() async throws {
        // The first connection is lost with two fifths on disk; every one after it is silent.
        let outcome = try await download(
            Self.payload(500_000),
            script: [.init(send: 200_000, ending: .hold), .init(send: 0, ending: .stall)],
            policy: Self.policy(idle: Self.impatient))

        let error = try #require(outcome.error as? ContainerizationError)
        #expect(error.code == .timeout)
        #expect(error.message.hasPrefix("download stalled:"))
        #expect(error.message.contains("0.2 of 0.5 MB received"))
        #expect(outcome.seen.map(\.range) == [nil, "bytes=200000-", "bytes=200000-", "bytes=200000-"])
    }

    @Test("a connection that keeps dropping ends as an interrupted download, under the same code")
    func givesUpWhenTheConnectionKeepsDropping() async throws {
        let outcome = try await download(Self.payload(), script: [.init(send: 0, ending: .hangUp)])

        let error = try #require(outcome.error as? ContainerizationError)
        #expect(error.code == .timeout)
        #expect(error.message.hasPrefix("download interrupted: the connection was lost"))
        #expect(outcome.seen.count == 3)
    }

    @Test("an answer that will not change is not asked for twice")
    func doesNotRetryARefusal() async throws {
        let outcome = try await download(Self.payload(), script: [.init(status: .notFound)])

        let error = try #require(outcome.error as? ContainerizationError)
        #expect(error.code == .notFound)
        #expect(error.message == "download failed: the server answered HTTP 404")
        #expect(outcome.seen.count == 1)
        #expect(outcome.file == nil)
    }

    @Test("a server that asks to be tried later is tried later")
    func retriesABusyServer() async throws {
        let payload = Self.payload()
        let outcome = try await download(payload, script: [.init(status: .serviceUnavailable), .init()])

        #expect(outcome.error == nil)
        #expect(outcome.file == payload)
        #expect(outcome.seen.count == 2)
    }

    @Test("neither the log nor the error repeats the source")
    func namesTheSourceNowhere() async throws {
        let resumed = try await download(Self.payload(), script: [.init(send: 40_000, ending: .hold), .init()])
        let abandoned = try await download(Self.payload(), script: [.init(send: 0, ending: .hangUp)])

        let messages = resumed.log.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        #expect(
            messages == [
                "FileDownloader: started", "FileDownloader: interrupted", "FileDownloader: retrying", "FileDownloader: completed",
            ])
        #expect(resumed.log.contains { $0.hasPrefix("FileDownloader: retrying") && $0.contains("resumeFrom=40000") })
        #expect(abandoned.log.last?.hasPrefix("FileDownloader: gave up") == true)
        let said = resumed.log + abandoned.log + [String(describing: try #require(abandoned.error))]
        for line in said {
            #expect(!line.contains("127.0.0.1"), "\(line)")
            #expect(!line.contains("secret-token"), "\(line)")
            #expect(!line.contains("payload.bin"), "\(line)")
        }
    }

    @Test("cancelling the task ends the download at once, stalled or not")
    func cancellationEndsTheDownload() async throws {
        let server = try FlakyFileServer(serving: Self.payload(), script: [.init(send: 10_000, ending: .stall)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-downloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.bin")
        let url = server.url

        let task = Task {
            try await FileDownloader.downloadFile(url: url, to: destination, policy: Self.policy(idle: .seconds(120)))
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while server.seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        task.cancel()
        let result = await task.result
        await server.shutdown()

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - cancelled < .seconds(30), "well inside the two minutes the silence would otherwise take")
        #expect(server.seen.count == 1)
    }

    @Test("a content range is read as the server wrote it, or not at all")
    func readsContentRanges() {
        #expect(FileDownloader.ContentRange("bytes 100-199/696573576")?.start == 100)
        #expect(FileDownloader.ContentRange("bytes 100-199/696573576")?.total == 696_573_576)
        #expect(FileDownloader.ContentRange("bytes 100-199/*")?.total == nil)
        #expect(FileDownloader.ContentRange("bytes 100-199/*")?.end == 199)
        for malformed in [nil, "", "bytes", "items 0-1/2", "bytes 5-1/10", "bytes 0-9/5", "bytes */10", "bytes a-b/c", "bytes 0-9"] {
            #expect(FileDownloader.ContentRange(malformed) == nil, "\(malformed ?? "nil")")
        }
    }

    @Test("only a strong entity tag or a date may vouch for a range")
    func choosesAValidator() {
        #expect(FileDownloader.validator(in: ["ETag": "\"0x8DED045CF4CB5A6\"", "Last-Modified": "then"]) == "\"0x8DED045CF4CB5A6\"")
        #expect(FileDownloader.validator(in: ["ETag": "W/\"weak\"", "Last-Modified": "then"]) == "then")
        #expect(FileDownloader.validator(in: ["ETag": "W/\"weak\""]) == nil)
        #expect(FileDownloader.validator(in: [:]) == nil)
    }
}

private final class CapturedLog: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

private struct CapturingLogHandler: LogHandler {
    let lines: CapturedLog
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let fields = (event.metadata ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        lines.append(([event.message.description] + fields).joined(separator: " "))
    }
}
