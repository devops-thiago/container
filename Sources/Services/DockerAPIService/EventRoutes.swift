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

/// `GET /events?since=&until=&filters=`: one JSON line per event, as it happens.
///
/// There is no history: `since` and `until` bound the live events only. An `until` already
/// past answers at once with nothing, as dockerd does once its history is spent; a later one
/// ends the stream then. The stream also ends when the client goes, or when the bus drops a
/// client that fell too far behind.
public enum EventRoutes {
    public static func register(on router: inout DockerRouter, events: DockerEventBus, now: @escaping @Sendable () -> Date = { Date() }) {
        router.add(.GET, "/events") { request, _ in try await stream(request, events: events, now: now) }
    }

    static func stream(_ request: DockerRequest, events: DockerEventBus, now: @escaping @Sendable () -> Date) async throws -> DockerResponse {
        let sinceText = request.query("since") ?? ""
        let untilText = request.query("until") ?? ""
        let since = try timestamp(sinceText, name: "since")
        let until = try timestamp(untilText, name: "until")
        if let until, until < (since ?? .distantPast) {
            throw DockerAPIError.badRequest("`since` time (\(sinceText)) cannot be after `until` time (\(untilText))")
        }
        let filter = try DockerEventFilter(try request.filters())
        if let until, until <= now() {
            return .stream(status: .ok, contentType: "application/json") { _ in }
        }
        // Subscribed before the head goes, so nothing that happens after the client sees it
        // is missed.
        let (id, stream) = try await events.subscribe(filter)
        return .stream(status: .ok, contentType: "application/json") { writer in
            let deadline = until.map { until in
                Task {
                    try? await Task.sleep(for: .seconds(until.timeIntervalSince(now())))
                    await events.cancel(id)
                }
            }
            defer {
                deadline?.cancel()
                Task { await events.cancel(id) }
            }
            for await event in stream {
                if let since, event.time < since { continue }
                if let until, event.time > until { break }
                try await writer.writeJSON(event.message)
            }
        }
    }

    /// A Unix time as dockerd reads one, `seconds[.fraction]`; nil when empty.
    static func timestamp(_ text: String, name: String) throws(DockerAPIError) -> Date? {
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int64(parts[0]) else {
            throw .badRequest("invalid value for '\(name)': strconv.ParseInt: parsing \"\(parts[0])\": invalid syntax")
        }
        var fraction = 0.0
        if parts.count == 2 {
            guard let digits = Int64(parts[1]), digits >= 0 else {
                throw .badRequest("invalid value for '\(name)': strconv.ParseInt: parsing \"\(parts[1])\": invalid syntax")
            }
            fraction = Double(digits) / pow(10, Double(parts[1].count))
        }
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
