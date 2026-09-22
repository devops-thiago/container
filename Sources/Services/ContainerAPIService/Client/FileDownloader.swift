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

import AsyncHTTPClient
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import SystemPackage
import TerminalProgress

public struct FileDownloader {
    /// How a download recovers from a connection that stops delivering.
    ///
    /// A large file over a consumer network meets connections that go silent without closing:
    /// a VPN that drops a flow, a filter that holds it, Wi-Fi that roamed. Nothing arrives and
    /// nothing fails, so without an idle timeout the transfer waits forever. With one the
    /// attempt ends, and the next asks the server for the rest of the file rather than for the
    /// whole of it again.
    public struct Policy: Sendable {
        /// How long a connection may deliver nothing before the attempt is abandoned. The clock
        /// runs between reads from the socket, so it also counts time in which this process did
        /// not get round to reading; abandoning such an attempt costs a reconnect and no data.
        public var idleTimeout: Duration
        /// How long to wait for a connection to open.
        public var connectTimeout: Duration
        /// How long to wait, redirects included, for the server to begin its answer.
        public var responseTimeout: Duration
        /// How many attempts in a row may end without adding to the file before giving up.
        /// An attempt that added something starts the count again, so a transfer that keeps
        /// advancing is not abandoned for the number of times it had to reconnect.
        public var fruitlessAttemptLimit: Int
        /// How many attempts one download may take in all, so that it always ends.
        public var attemptLimit: Int
        /// The wait before the first retry. It doubles after every fruitless attempt.
        public var initialBackoff: Duration
        /// The longest wait between two attempts.
        public var maximumBackoff: Duration

        public init(
            idleTimeout: Duration = .seconds(30),
            connectTimeout: Duration = .seconds(30),
            responseTimeout: Duration = .seconds(60),
            fruitlessAttemptLimit: Int = 5,
            attemptLimit: Int = 100,
            initialBackoff: Duration = .seconds(1),
            maximumBackoff: Duration = .seconds(15)
        ) {
            self.idleTimeout = idleTimeout
            self.connectTimeout = connectTimeout
            self.responseTimeout = responseTimeout
            self.fruitlessAttemptLimit = max(1, fruitlessAttemptLimit)
            self.attemptLimit = max(1, attemptLimit)
            self.initialBackoff = initialBackoff
            self.maximumBackoff = maximumBackoff
        }

        public static let `default` = Policy()
    }

    /// Downloads `url` to `destination`, replacing whatever is there.
    ///
    /// The transfer is abandoned and tried again when the connection delivers nothing for
    /// `policy.idleTimeout`, when it is lost, and when the server asks to be tried later. A
    /// retry continues from the bytes already on disk when the server offers ranges, and says
    /// which version of the file those bytes came from, so a file that changed in between is
    /// fetched whole instead of being stitched together from two versions.
    ///
    /// Nothing logged here names the URL or anything derived from it: a source can carry a
    /// token or an internal hostname, and the daemon's log is world-readable. For the same
    /// reason the errors thrown name neither, because the daemon logs what its routes throw.
    public static func downloadFile(
        url: URL,
        to destination: URL,
        progressUpdate: ProgressUpdateHandler? = nil,
        policy: Policy = .default,
        log: Logger? = nil
    ) async throws {
        let client = FileDownloader.createClient(url: url, policy: policy)
        var transfer = Transfer(
            client: client,
            url: url,
            destination: SystemPackage.FilePath(destination.path),
            progressUpdate: progressUpdate,
            policy: policy,
            log: log)
        do {
            try await transfer.run()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    private static func createClient(url: URL, policy: Policy) -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        // `read` is an idle timeout, not a limit on the whole transfer: it starts again with
        // every read, so a slow download that keeps arriving is never cut short.
        httpConfiguration.timeout = HTTPClient.Configuration.Timeout(
            connect: TimeAmount(policy.connectTimeout),
            read: TimeAmount(policy.idleTimeout)
        )
        if let host = url.host {
            let proxyURL = ProxyUtils.proxyFromEnvironment(scheme: url.scheme, host: host)
            if let proxyURL, let proxyHost = proxyURL.host {
                httpConfiguration.proxy = HTTPClient.Configuration.Proxy.server(host: proxyHost, port: proxyURL.port ?? 8080)
            }
        }

        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }
}

extension FileDownloader {
    /// Why an attempt ended before the file was whole, when another attempt may do better.
    enum Interruption: Error, Equatable {
        /// The connection stayed open and delivered nothing for the idle timeout.
        case stalled
        /// No connection, or no answer, in the time allowed.
        case noResponse
        /// The transport failed underneath the transfer: reset, closed early, DNS, TLS.
        case connectionLost(String)
        /// The server asked to be tried later.
        case serverBusy(UInt)
        /// The server would not continue from the bytes on disk. They have been discarded.
        case resumeRefused
    }

    /// A failure writing the file, kept apart from the transport's failures because trying
    /// again cannot help with a full disk.
    private struct LocalFileFailure: Error {
        let cause: any Error
    }

    /// `bytes 100-199/696573576`, where the total may be `*`.
    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64?

        init?(_ value: String?) {
            guard let value else { return nil }
            let fields = value.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
            let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start else {
                return nil
            }
            if parts[1] == "*" {
                self.total = nil
            } else {
                guard let total = Int64(parts[1]), total > end else { return nil }
                self.total = total
            }
            self.start = start
            self.end = end
        }
    }

    /// What to send as `If-Range`: a strong entity tag, or failing that the modification date.
    /// A weak tag cannot vouch for a byte range, and a server that gets one answers with the
    /// whole file.
    static func validator(in headers: HTTPHeaders) -> String? {
        if let tag = headers.first(name: "ETag")?.trimmingCharacters(in: .whitespaces), tag.hasPrefix("\""), tag.count > 1 {
            return tag
        }
        return headers.first(name: "Last-Modified")
    }

    /// One download: the state that outlives an attempt, and the loop that spends the policy.
    private struct Transfer {
        /// How much may arrive between two progress reports. Every chunk would be thousands
        /// of messages a second on a fast link.
        static let progressGranularity: Int64 = 256 * 1024

        let client: HTTPClient
        let url: URL
        let destination: SystemPackage.FilePath
        let progressUpdate: ProgressUpdateHandler?
        let policy: Policy
        let log: Logger?

        /// Whether the server has said it serves ranges.
        var acceptsRanges = false
        /// What identifies the version of the file the bytes on disk came from.
        var validator: String?
        /// The size of the whole file, once a response has said.
        var total: Int64?
        /// How much of `total` the progress handler has been told about.
        var announcedTotal: Int64 = 0
        /// Whether the progress handler is showing a note about a retry.
        var showingRetryNote = false

        mutating func run() async throws {
            let started = ContinuousClock.now
            var attempt = 0
            var fruitless = 0
            var backoff = policy.initialBackoff
            // Whatever is at the destination is not ours to continue from.
            try discardPartialFile()
            log?.info("FileDownloader: started")

            while true {
                try Task.checkCancellation()
                attempt += 1
                let offset = try resumeOffset()
                let interruption: Interruption
                do {
                    let size = try await self.attempt(from: offset)
                    log?.info(
                        "FileDownloader: completed",
                        metadata: [
                            "bytes": "\(size)",
                            "attempts": "\(attempt)",
                            "seconds": "\((ContinuousClock.now - started).components.seconds)",
                        ])
                    return
                } catch let ended as Interruption {
                    interruption = ended
                }

                let kept = try resumeOffset()
                // Only bytes the next attempt can continue from count as having advanced.
                if kept > offset {
                    fruitless = 0
                    backoff = policy.initialBackoff
                } else {
                    fruitless += 1
                }
                log?.info(
                    "FileDownloader: interrupted",
                    metadata: [
                        "reason": "\(Self.label(interruption))",
                        "attempt": "\(attempt)",
                        "keptBytes": "\(kept)",
                        "totalBytes": "\(total.map(String.init) ?? "unknown")",
                    ])

                guard fruitless < policy.fruitlessAttemptLimit, attempt < policy.attemptLimit else {
                    let failure = failure(for: interruption, attempts: attempt, fruitless: fruitless, kept: kept)
                    log?.error(
                        "FileDownloader: gave up",
                        metadata: [
                            "reason": "\(Self.label(interruption))",
                            "attempts": "\(attempt)",
                        ])
                    throw failure
                }

                log?.info(
                    "FileDownloader: retrying",
                    metadata: [
                        "attempt": "\(attempt + 1)",
                        "resumeFrom": "\(kept)",
                        "delayMilliseconds": "\(Self.milliseconds(backoff))",
                    ])
                await report([.setSubDescription("\(Self.describe(interruption, policy: policy)), retrying")])
                showingRetryNote = true
                try await Task.sleep(for: backoff)
                if kept <= offset {
                    backoff = min(backoff * 2, policy.maximumBackoff)
                }
            }
        }

        /// One request, written to the file from `offset`. Returns the size of the file.
        private mutating func attempt(from offset: Int64) async throws -> Int64 {
            if let total, offset == total {
                // Every byte arrived and the attempt still failed, in the moment between the
                // last of the body and the end of the stream. There is nothing left to ask for.
                return total
            }

            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .GET
            if offset > 0 {
                request.headers.add(name: "Range", value: "bytes=\(offset)-")
                if let validator {
                    request.headers.add(name: "If-Range", value: validator)
                }
            }

            let response: HTTPClientResponse
            do {
                // The deadline covers up to the response head and no further; the idle timeout
                // watches the body, however long that takes.
                response = try await client.execute(request, deadline: .now() + TimeAmount(policy.responseTimeout))
            } catch {
                throw Self.translate(error)
            }

            let writeFrom: Int64
            switch response.status.code {
            case 200:
                // The whole file: a first request, a server without ranges, or a file that is
                // no longer the version the bytes on disk came from.
                writeFrom = 0
                total = response.headers.first(name: "Content-Length").flatMap { Int64($0) }
            case 206 where offset > 0:
                guard let range = ContentRange(response.headers.first(name: "Content-Range")),
                    range.start == offset,
                    total == nil || range.total == nil || range.total == total
                else {
                    try discardPartialFile()
                    throw Interruption.resumeRefused
                }
                writeFrom = offset
                total = range.total ?? total
            case 416 where offset > 0:
                try discardPartialFile()
                throw Interruption.resumeRefused
            case 408, 425, 429, 500, 502, 503, 504:
                throw Interruption.serverBusy(response.status.code)
            case let status:
                throw ContainerizationError(
                    status == 404 || status == 410 ? .notFound : .invalidState,
                    message: "download failed: the server answered HTTP \(status)")
            }
            acceptsRanges =
                response.status.code == 206
                || response.headers[canonicalForm: "Accept-Ranges"].contains { $0.lowercased() == "bytes" }
            // A whole file is whatever version this response says it is, even one that no longer
            // names itself: keeping the old name would have every later range refused.
            let named = FileDownloader.validator(in: response.headers)
            validator = response.status.code == 200 ? named : named ?? validator

            var events: [ProgressUpdateEvent] = []
            if let total, total != announcedTotal {
                events.append(.addTotalSize(total - announcedTotal))
                announcedTotal = total
            }
            if showingRetryNote {
                events.append(.setSubDescription(""))
                showingRetryNote = false
            }
            events.append(.setSize(writeFrom))
            await report(events)

            let written = try await write(response.body, from: writeFrom)
            if let total, written < total {
                throw Interruption.connectionLost("the connection closed early")
            }
            return written
        }

        /// Writes the body after the first `offset` bytes of the file. Returns the file's size.
        private func write(_ body: HTTPClientResponse.Body, from offset: Int64) async throws -> Int64 {
            let file: SystemPackage.FileDescriptor
            do {
                file = try SystemPackage.FileDescriptor.open(
                    destination,
                    .writeOnly,
                    options: offset == 0 ? [.create, .truncate] : [.append],
                    permissions: [.ownerReadWrite, .groupRead, .otherRead])
            } catch {
                throw Self.fileFailure(error)
            }

            var written = offset
            var unreported: Int64 = 0
            do {
                for try await chunk in body {
                    do {
                        try file.writeAll(chunk.readableBytesView)
                    } catch {
                        throw LocalFileFailure(cause: error)
                    }
                    written += Int64(chunk.readableBytes)
                    unreported += Int64(chunk.readableBytes)
                    if unreported >= Self.progressGranularity {
                        unreported = 0
                        await report([.setSize(written)])
                    }
                }
            } catch {
                try? file.close()
                if unreported > 0 {
                    await report([.setSize(written)])
                }
                if let failure = error as? LocalFileFailure {
                    throw Self.fileFailure(failure.cause)
                }
                throw Self.translate(error)
            }

            do {
                try file.close()
            } catch {
                throw Self.fileFailure(error)
            }
            await report([.setSize(written)])
            return written
        }

        /// Where the next attempt starts: the end of the file on disk when the server can
        /// continue from there, otherwise the beginning.
        private func resumeOffset() throws -> Int64 {
            guard acceptsRanges, validator != nil || total != nil else { return 0 }
            var status = stat()
            guard stat(destination.string, &status) == 0 else {
                if errno == ENOENT { return 0 }
                throw Self.fileFailure(SystemPackage.Errno(rawValue: errno))
            }
            if let total, status.st_size > total { return 0 }
            return Int64(status.st_size)
        }

        private func discardPartialFile() throws {
            guard unlink(destination.string) != 0, errno != ENOENT else { return }
            throw Self.fileFailure(SystemPackage.Errno(rawValue: errno))
        }

        private func report(_ events: [ProgressUpdateEvent]) async {
            guard let progressUpdate, !events.isEmpty else { return }
            await progressUpdate(events)
        }

        /// What giving up says. The message names how far the transfer got, because "stalled
        /// at 17%" and "never started" send someone looking in different places.
        private func failure(for interruption: Interruption, attempts: Int, fruitless: Int, kept: Int64) -> ContainerizationError {
            let reason = Self.describe(interruption, policy: policy)
            let count =
                fruitless >= policy.fruitlessAttemptLimit
                ? "\(fruitless) attempts in a row ended without receiving anything new"
                : "it took \(attempts) attempts without finishing"
            let progress =
                total.map { "\(Self.megabytes(kept)) of \(Self.megabytes($0)) MB received" }
                ?? "\(Self.megabytes(kept)) MB received"
            let advice = "Check the network connection and any VPN, proxy or content filter, then try again."
            // One code for every way of giving up, and no other error of a download carries it:
            // a caller tells "the network would not let this finish" from a wrong address or a
            // full disk by the code alone, without reading the message.
            switch interruption {
            case .stalled, .noResponse:
                return ContainerizationError(
                    .timeout,
                    message: "download stalled: \(reason), and \(count) (\(progress)). \(advice)")
            case .connectionLost, .serverBusy, .resumeRefused:
                return ContainerizationError(
                    .timeout,
                    message: "download interrupted: \(reason), and \(count) (\(progress)). \(advice)")
            }
        }

        private static func describe(_ interruption: Interruption, policy: Policy) -> String {
            switch interruption {
            case .stalled:
                "no data arrived for \(Self.seconds(policy.idleTimeout))"
            case .noResponse:
                "the server did not answer in time"
            case .connectionLost(let detail):
                "the connection was lost (\(detail))"
            case .serverBusy(let status):
                "the server answered HTTP \(status)"
            case .resumeRefused:
                "the server would not continue the transfer"
            }
        }

        private static func label(_ interruption: Interruption) -> String {
            switch interruption {
            case .stalled: "stalled"
            case .noResponse: "no response"
            case .connectionLost(let detail): "connection lost: \(detail)"
            case .serverBusy(let status): "HTTP \(status)"
            case .resumeRefused: "resume refused"
            }
        }

        private static func megabytes(_ bytes: Int64) -> String {
            String(format: "%.1f", Double(bytes) / 1_000_000)
        }

        private static func seconds(_ duration: Duration) -> String {
            let value = Double(milliseconds(duration)) / 1000
            return value == 1 ? "1 second" : "\(String(format: "%g", value)) seconds"
        }

        private static func milliseconds(_ duration: Duration) -> Int64 {
            let components = duration.components
            return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        }

        /// Sorts what the HTTP client throws into what another attempt may fix and what it
        /// will not. Transport errors are described by their type alone: their own
        /// descriptions name the host.
        private static func translate(_ error: any Error) -> any Error {
            if error is CancellationError || Task.isCancelled {
                return CancellationError()
            }
            if let interruption = error as? Interruption {
                return interruption
            }
            if let error = error as? ContainerizationError {
                return error
            }
            guard let clientError = error as? HTTPClientError else {
                return Interruption.connectionLost(String(describing: type(of: error)))
            }
            switch clientError {
            case .readTimeout:
                return Interruption.stalled
            case .connectTimeout, .deadlineExceeded, .getConnectionFromPoolTimeout, .tlsHandshakeTimeout,
                .socksHandshakeTimeout, .httpProxyHandshakeTimeout:
                return Interruption.noResponse
            case .remoteConnectionClosed, .uncleanShutdown, .requestStreamCancelled:
                return Interruption.connectionLost(clientError.shortDescription)
            default:
                return ContainerizationError(.invalidArgument, message: "download failed: \(clientError.shortDescription)")
            }
        }

        private static func fileFailure(_ error: any Error) -> ContainerizationError {
            // An `Errno` describes itself without the path, which is derived from the URL.
            let detail = (error as? SystemPackage.Errno).map(String.init(describing:)) ?? String(describing: type(of: error))
            return ContainerizationError(.internalError, message: "download failed: could not write the file (\(detail))")
        }
    }
}
