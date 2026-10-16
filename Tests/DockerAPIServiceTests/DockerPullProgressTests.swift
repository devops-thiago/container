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
import NIOCore
import Synchronization
import Testing

@testable import DockerAPIService

/// An images service in memory: a pull reports the events it was given and answers with the
/// digest, or fails.
final class FakeImages: EngineImages, Sendable {
    private let state = Mutex<(pulls: [String], events: [[DockerPullEvent]], failure: DockerAPIError?, updated: Bool)>(([], [], nil, true))

    var pulls: [String] { state.withLock { $0.pulls } }

    func script(events: [[DockerPullEvent]], failure: DockerAPIError? = nil, updated: Bool = true) {
        state.withLock {
            $0.events = events
            $0.failure = failure
            $0.updated = updated
        }
    }

    func pull(reference: String, platform: String?, progress: @escaping @Sendable ([DockerPullEvent]) -> Void) async throws -> DockerPulledImage {
        let (events, failure, updated) = state.withLock { state in
            state.pulls.append("\(reference) \(platform ?? "-")")
            return (state.events, state.failure, state.updated)
        }
        for batch in events {
            progress(batch)
            // Let the route write a line for it.
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure { throw failure }
        return DockerPulledImage(digest: "sha256:" + String(repeating: "a", count: 64), updated: updated)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DockerPullProgressTests {
    @Test("a reference is split as the progress lines and the engine need it")
    func references() throws {
        let alpine = try DockerPullReference(fromImage: "alpine", tag: "3.22")
        #expect(alpine.reference == "alpine:3.22")
        #expect(alpine.repository == "library/alpine")
        #expect(alpine.tagOrDigest == "3.22")
        #expect(alpine.familiar == "alpine:3.22")
        let latest = try DockerPullReference(fromImage: "docker.io/library/busybox", tag: nil)
        #expect(latest.reference == "docker.io/library/busybox:latest")
        #expect(latest.repository == "library/busybox")
        #expect(latest.familiar == "busybox:latest")
        let registry = try DockerPullReference(fromImage: "localhost:5000/team/app", tag: "v1")
        #expect(registry.repository == "team/app")
        #expect(registry.familiar == "localhost:5000/team/app:v1")
        let digest = "sha256:" + String(repeating: "b", count: 64)
        let pinned = try DockerPullReference(fromImage: "ghcr.io/org/app", tag: digest)
        #expect(pinned.reference == "ghcr.io/org/app@" + digest)
        #expect(pinned.tagOrDigest == digest)
        let inline = try DockerPullReference(fromImage: "alpine:3.21", tag: "")
        #expect(inline.reference == "alpine:3.21")
        // Control: what dockerd calls an invalid reference format is refused.
        for bad in ["Alpine", "alpine//x", "/alpine", "alpine:", "-alpine"] {
            #expect(throws: DockerAPIError.self, "\(bad)") { try DockerPullReference(fromImage: bad, tag: nil) }
        }
        #expect(throws: DockerAPIError.self) { try DockerPullReference(fromImage: "alpine", tag: "bad tag") }
    }

    @Test("progress sums events in any order, never shows done past the total, and switches to Extracting")
    func progress() {
        var progress = DockerPullProgress()
        progress.apply([.addTotalItems(3), .addSize(400)])
        progress.apply([.addTotalSize(1000), .addItems(1)])
        let line = progress.message(id: "3.22")
        #expect(line.status == "Downloading")
        #expect(line.id == "3.22")
        #expect(line.progressDetail == .init(current: 400, total: 1000))
        #expect(line.progress == "[====================>                             ] 400B/1kB")
        // Sizes that arrive before their totals are not shown past them.
        progress.apply([.addSize(900)])
        #expect(progress.message(id: "x").progressDetail == .init(current: 1000, total: 1000))
        #expect(progress.message(id: "x").progress?.hasPrefix("[" + String(repeating: "=", count: 50) + "]") == true)
        // Control: with no total yet, the size alone, and no total in the detail.
        var early = DockerPullProgress()
        early.apply([.addSize(1_234_567)])
        #expect(early.message(id: "x").progressDetail == .init(current: 1_234_567, total: nil))
        #expect(early.message(id: "x").progress == "1.235MB")
        progress.apply([.extracting])
        #expect(progress.message(id: "3.22") == DockerProgressMessage(status: "Extracting", id: "3.22"))
    }

    @Test("sizes are written in decimal units with four significant digits")
    func humanSize() {
        #expect(DockerPullProgress.humanSize(0) == "0B")
        #expect(DockerPullProgress.humanSize(999) == "999B")
        #expect(DockerPullProgress.humanSize(1000) == "1kB")
        #expect(DockerPullProgress.humanSize(3_620_000) == "3.62MB")
        #expect(DockerPullProgress.humanSize(2_500_000_000) == "2.5GB")
    }

    @Test("messages encode in Docker's field names, and a failure as errorDetail and error")
    func encoding() throws {
        let line = DockerProgressMessage(status: "Downloading", id: "3.22", progressDetail: .init(current: 1, total: 2), progress: "[>] 1B/2B")
        let object = try #require(try JSONSerialization.jsonObject(with: DockerJSON.encoder.encode(line)) as? [String: Any])
        #expect(Set(object.keys) == ["status", "id", "progressDetail", "progress"])
        #expect((object["progressDetail"] as? [String: Int]) == ["current": 1, "total": 2])
        let failure = try #require(try JSONSerialization.jsonObject(with: DockerJSON.encoder.encode(DockerProgressMessage.failure("denied"))) as? [String: Any])
        #expect(failure["error"] as? String == "denied")
        #expect((failure["errorDetail"] as? [String: String]) == ["message": "denied"])
        // Control: a status line carries neither.
        #expect(object["error"] == nil && object["errorDetail"] == nil)
    }

    struct Harness {
        let images = FakeImages()
        let server: DockerAPIServerTests.Harness

        init() async throws {
            let images = self.images
            server = try await DockerAPIServerTests.Harness.start { ImageRoutes.register(on: &$0, engine: images, progressInterval: .milliseconds(1)) }
        }

        func pull(_ query: String, headers: String = "") async throws -> (head: String, lines: [[String: Any]]) {
            var head = ""
            var lines: [[String: Any]] = []
            try await server.withClient { client in
                try await client.send("POST /v1.48/images/create?\(query) HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\(headers)\r\n")
                head = try await client.read(through: "\r\n\r\n")
                let body = try await client.readToEnd()
                // Chunked: the JSON lines are what is between the chunk sizes.
                // Split on bytes: a Swift string reads "\r\n" as one character.
                for line in body.utf8.split(separator: UInt8(ascii: "\n")).map({ String(decoding: $0, as: UTF8.self) }) where line.hasPrefix("{") {
                    if let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                        lines.append(object)
                    }
                }
            }
            return (head, lines)
        }
    }

    @Test("a pull streams Pulling from, progress, the digest and Downloaded newer image")
    func pullStream() async throws {
        let h = try await Harness()
        defer { Task { try? await h.server.stop() } }
        h.images.script(events: [[.addTotalSize(2000), .addTotalItems(2)], [.addSize(1000)], [.addSize(1000), .addItems(2)], [.extracting]])
        let (head, lines) = try await h.pull("fromImage=busybox&tag=1.37", headers: "X-Registry-Auth: e30=\r\n")
        #expect(head.hasPrefix("HTTP/1.1 200"))
        #expect(head.contains("Content-Type: application/json"))
        let statuses = lines.compactMap { $0["status"] as? String }
        #expect(statuses.first == "Pulling from library/busybox")
        #expect(statuses.contains("Downloading"))
        #expect(statuses.suffix(3) == ["Pull complete", "Digest: sha256:" + String(repeating: "a", count: 64), "Status: Downloaded newer image for busybox:1.37"])
        #expect(lines.allSatisfy { $0["error"] == nil })
        #expect(h.images.pulls == ["busybox:1.37 -"])
        // Control: an image that was already up to date says so.
        h.images.script(events: [], updated: false)
        let again = try await h.pull("fromImage=busybox&tag=1.37&platform=linux/arm64")
        #expect(again.lines.last?["status"] as? String == "Status: Image is up to date for busybox:1.37")
        #expect(h.images.pulls.last == "busybox:1.37 linux/arm64")
    }

    @Test("a failure after the head is the last line, as errorDetail and error")
    func pullFailure() async throws {
        let h = try await Harness()
        defer { Task { try? await h.server.stop() } }
        h.images.script(events: [[.addTotalSize(10)]], failure: .notFound("pull access denied for nope, repository does not exist"))
        let (head, lines) = try await h.pull("fromImage=nope&tag=latest")
        #expect(head.hasPrefix("HTTP/1.1 200"))
        let last = try #require(lines.last)
        #expect(last["error"] as? String == "pull access denied for nope, repository does not exist")
        #expect((last["errorDetail"] as? [String: String])?["message"] == "pull access denied for nope, repository does not exist")
        #expect(!lines.contains { ($0["status"] as? String)?.hasPrefix("Status:") == true })
    }

    @Test("what can be refused is refused before the head")
    func pullRefusals() async throws {
        let h = try await Harness()
        defer { Task { try? await h.server.stop() } }
        #expect(try await h.pull("fromImage=Bad").head.hasPrefix("HTTP/1.1 400"))
        #expect(try await h.pull("tag=latest").head.hasPrefix("HTTP/1.1 400"))
        #expect(try await h.pull("fromImage=busybox&platform=linux").head.hasPrefix("HTTP/1.1 400"))
        #expect(try await h.pull("fromSrc=-&repo=x").head.hasPrefix("HTTP/1.1 501"))
        #expect(h.images.pulls.isEmpty)
        // Control: a valid request with a platform goes through.
        #expect(try await h.pull("fromImage=busybox&platform=linux/arm64/v8").head.hasPrefix("HTTP/1.1 200"))
    }
}
