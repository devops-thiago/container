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
import Testing

@testable import DockerAPIService

/// Builds tar archives for the tests, malicious ones included: the writer's headers do not
/// check names.
struct TarBuilder {
    var bytes: [UInt8] = []

    mutating func file(_ name: String, _ content: String, mode: UInt32 = 0o644) {
        let data = Array(content.utf8)
        bytes += DockerTar.header(.init(name: name, type: .file, mode: mode, size: UInt64(data.count), mtime: Fixtures.now))
        bytes += data + DockerTar.padding(data.count)
    }

    mutating func directory(_ name: String, mode: UInt32 = 0o755) {
        bytes += DockerTar.header(.init(name: name.hasSuffix("/") ? name : name + "/", type: .directory, mode: mode, mtime: Fixtures.now))
    }

    mutating func symlink(_ name: String, to target: String) {
        bytes += DockerTar.header(.init(name: name, type: .symlink, mode: 0o777, mtime: Fixtures.now, linkTarget: target))
    }

    mutating func hardLink(_ name: String, to target: String) {
        bytes += DockerTar.header(.init(name: name, type: .hardLink, mode: 0o644, mtime: Fixtures.now, linkTarget: target))
    }

    mutating func entry(_ name: String, type: DockerTar.EntryType) {
        bytes += DockerTar.header(.init(name: name, type: type, mode: 0o644, mtime: Fixtures.now))
    }

    var archive: [UInt8] { bytes + DockerTar.end }
}

@Suite(.timeLimit(.minutes(1)))
struct TarGuardTests {
    final class Scratch {
        let top = FileManager.default.temporaryDirectory.appending(path: "dapi-tar-\(UUID().uuidString.prefix(8))")
        var root: URL { top.appending(path: "root") }
        var outside: URL { top.appending(path: "outside") }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: top) }

        func extract(_ archive: [UInt8], maxBytes: Int = 1 << 20, maxEntries: Int = 100) throws -> [DockerExtractedEntry] {
            let url = top.appending(path: "upload-\(UUID().uuidString).tar")
            try Data(archive).write(to: url)
            return try DockerTarExtractor(maxBytes: maxBytes, maxEntries: maxEntries).extract(url, into: root)
        }

        func contents(_ path: String) -> String? {
            (try? String(contentsOf: root.appending(path: path), encoding: .utf8))
        }

        /// Everything anywhere under the scratch directory but the root and the uploads.
        var leaked: [String] {
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: top.path)) ?? []
            return all.filter { !$0.hasPrefix("root") && !$0.hasSuffix(".tar") && $0 != "outside" }
        }
    }

    @Test("a well-formed archive unpacks: files with their modes, directories, links that stay inside, and its top-level names")
    func benign() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.directory("app")
        tar.file("app/run.sh", "echo hi", mode: 0o755)
        tar.file("./notes.txt", "notes")
        tar.symlink("app/latest", to: "run.sh")
        tar.symlink("app/up", to: "../notes.txt")
        tar.hardLink("app/again.sh", to: "app/run.sh")
        tar.file("deep/inside/x", "x")
        let entries = try scratch.extract(tar.archive)
        #expect(entries.map(\.name) == ["app", "notes.txt", "deep"])
        #expect(entries.map(\.isDirectory) == [true, false, true])
        #expect(entries[1].mode == 0o644)
        #expect(scratch.contents("app/run.sh") == "echo hi")
        #expect(scratch.contents("app/latest") == "echo hi")
        #expect(scratch.contents("app/up") == "notes")
        #expect(scratch.contents("app/again.sh") == "echo hi")
        #expect(scratch.contents("deep/inside/x") == "x")
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.root.appending(path: "app/run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(scratch.leaked.isEmpty)
    }

    @Test("names that climb out or are absolute are refused, and nothing is written outside")
    func traversal() throws {
        for name in ["../escape", "a/../../escape", "/etc/escape", "./../escape"] {
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.file(name, "pwned")
            #expect(throws: DockerTarRejection.self, "\(name)") { try scratch.extract(tar.archive) }
            #expect(scratch.leaked.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: scratch.top.appending(path: "escape").path))
        }
    }

    @Test("symlinks that point out are refused, and so is writing through any symlink")
    func symlinkEscape() throws {
        for (name, target) in [("l", "../outside"), ("a/l", "../../outside"), ("abs", "/etc"), ("empty", "")] {
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.symlink(name, to: target)
            #expect(throws: DockerTarRejection.self, "\(name) -> \(target)") { try scratch.extract(tar.archive) }
        }
        // A link that stays inside, then an entry written through it: refused all the same.
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.directory("real")
        tar.symlink("via", to: "real")
        tar.file("via/file", "through the link")
        #expect(throws: DockerTarRejection.self) { try scratch.extract(tar.archive) }
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appending(path: "real/file").path))
    }

    @Test("a file over a link already unpacked is refused rather than written through it")
    func noFollowOnOverwrite() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.file("target.txt", "original")
        tar.symlink("link", to: "target.txt")
        tar.file("link", "replaced")
        #expect(throws: DockerTarRejection.self) { try scratch.extract(tar.archive) }
        #expect(scratch.contents("target.txt") == "original")
        // Control: a file replacing a file is the last one's.
        let again = try Scratch()
        var twice = TarBuilder()
        twice.file("f", "first")
        twice.file("f", "second")
        _ = try again.extract(twice.archive)
        #expect(again.contents("f") == "second")
    }

    @Test("hard links must name a file the archive unpacked")
    func hardLinks() throws {
        for target in ["../../etc/passwd", "/etc/passwd", "missing"] {
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.hardLink("h", to: target)
            #expect(throws: DockerTarRejection.self, "\(target)") { try scratch.extract(tar.archive) }
        }
    }

    @Test("the size and entry bounds hold before anything past them is written")
    func bounds() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.file("a", String(repeating: "x", count: 600))
        tar.file("b", String(repeating: "y", count: 600))
        #expect(throws: DockerTarRejection.self) { try scratch.extract(tar.archive, maxBytes: 1000) }
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appending(path: "b").path))
        // Control: within the bound it unpacks.
        let roomy = try Scratch()
        #expect(try roomy.extract(tar.archive, maxBytes: 1200).count == 2)

        let many = try Scratch()
        var entries = TarBuilder()
        for index in 0..<5 { entries.file("f\(index)", "") }
        #expect(throws: DockerTarRejection.self) { try many.extract(entries.archive, maxEntries: 4) }
    }

    @Test("devices and pipes are refused; a corrupt header is refused")
    func unsupported() throws {
        for type in [DockerTar.EntryType.characterDevice, .blockDevice, .fifo] {
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.entry("dev", type: type)
            #expect(throws: DockerTarRejection.self) { try scratch.extract(tar.archive) }
        }
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.file("a", "x")
        var corrupt = tar.archive
        corrupt[0] = UInt8(ascii: "b")
        #expect(throws: DockerTarRejection.self) { try scratch.extract(corrupt) }
    }

    @Test("long names travel in pax headers both ways, and a pax path is checked like any other")
    func longNames() throws {
        let scratch = try Scratch()
        let long = String(repeating: "d", count: 120) + "/" + String(repeating: "f", count: 120)
        var tar = TarBuilder()
        tar.file(long, "long")
        _ = try scratch.extract(tar.archive)
        #expect(scratch.contents(long) == "long")
        let evil = String(repeating: "../", count: 40) + "escape"
        var bad = TarBuilder()
        bad.file(evil, "x")
        let other = try Scratch()
        #expect(throws: DockerTarRejection.self) { try other.extract(bad.archive) }
    }

    @Test("ustar's prefix field joins the name")
    func ustarPrefix() throws {
        let scratch = try Scratch()
        let name = String(repeating: "p", count: 90) + "/" + String(repeating: "n", count: 60)
        let header = DockerTar.header(.init(name: name, type: .file, mode: 0o644, size: 1, mtime: Fixtures.now))
        // Split into prefix and name, with no pax header in front.
        #expect(header.count == DockerTar.blockSize)
        _ = try scratch.extract(header + Array("z".utf8) + DockerTar.padding(1) + DockerTar.end)
        #expect(scratch.contents(name) == "z")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct PathStatTests {
    @Test("the stat header's mode is Go's FileMode: the directory and link bits where the CLI looks for them")
    func goMode() {
        let directory = DockerPathStat.goMode(posix: 0o040755)
        #expect(directory == (1 << 31) | 0o755)
        #expect(DockerPathStat(name: "d", size: 0, mode: directory, mtime: Fixtures.now).isDirectory)
        // Control: the POSIX mode as it is would not read as a directory.
        #expect(!DockerPathStat(name: "d", size: 0, mode: 0o040755, mtime: Fixtures.now).isDirectory)
        #expect(DockerPathStat.goMode(posix: 0o120777) == (1 << 27) | 0o777)
        #expect(DockerPathStat.goMode(posix: 0o100644) == 0o644)
        #expect(DockerPathStat.goMode(posix: 0o104755) == (1 << 23) | 0o755)
        #expect(DockerPathStat.goMode(posix: 0o020600) == (1 << 26) | (1 << 21) | 0o600)
    }

    @Test("the header is standard base64 of the JSON the CLI decodes")
    func header() throws {
        let stat = DockerPathStat(name: "hosts", size: 174, mode: 0o644, mtime: Fixtures.now, linkTarget: "")
        let decoded = try #require(Data(base64Encoded: stat.headerValue))
        let object = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        #expect(object["name"] as? String == "hosts")
        #expect(object["size"] as? Int == 174)
        #expect(object["mode"] as? Int == 0o644)
        #expect(object["mtime"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(object["linkTarget"] as? String == "")
        #expect(!stat.headerValue.contains("-") && !stat.headerValue.contains("_"))
    }

    @Test("stat -c '%f %s %Y' output reads as a stat; anything else does not")
    func parseStat() {
        let stat = DockerPathStat.parse(statOutput: "41ed 4096 1800000000\n", name: "etc")
        #expect(stat?.isDirectory == true)
        #expect(stat?.size == 4096)
        #expect(stat?.mtime == Fixtures.now)
        #expect(DockerPathStat.parse(statOutput: "stat: can't stat", name: "x") == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ArchiveRouteTests {
    static func tarEntries(_ bytes: [UInt8]) throws -> [String: String] {
        let url = FileManager.default.temporaryDirectory.appending(path: "dapi-get-\(UUID().uuidString).tar")
        let root = FileManager.default.temporaryDirectory.appending(path: "dapi-get-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: root)
        }
        try Data(bytes).write(to: url)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try DockerTarExtractor(maxBytes: 1 << 20, maxEntries: 100).extract(url, into: root)
        var result: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory)
            result[path] = isDirectory.boolValue ? "/" : try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
        return result
    }

    static func stat(_ answer: ToolHarness.Answer) throws -> [String: Any] {
        let value = try #require(answer.header(DockerPathStat.headerName))
        let data = try #require(Data(base64Encoded: value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("PUT then GET round-trips a file and a directory, with the stat header and the file's mode")
    func roundTrip() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "tmp"), withIntermediateDirectories: true)
        var tar = TarBuilder()
        tar.file("greeting.txt", "hello archive\n", mode: 0o755)
        tar.directory("sub")
        tar.file("sub/inner.txt", "nested\n")
        let put = try await h.request("PUT", "/containers/box/archive?path=/tmp", body: tar.archive, contentType: "application/x-tar")
        #expect(put.status == 200)
        #expect(h.tools.copyCalls.contains("in greeting.txt /tmp 755"))
        #expect(try String(contentsOf: h.tools.root.appending(path: "tmp/sub/inner.txt"), encoding: .utf8) == "nested\n")

        let file = try await h.request("GET", "/containers/box/archive?path=/tmp/greeting.txt")
        #expect(file.status == 200)
        #expect(file.header("Content-Type") == "application/x-tar")
        #expect(try Self.tarEntries(file.body) == ["greeting.txt": "hello archive\n"])
        let fileStat = try Self.stat(file)
        #expect(fileStat["name"] as? String == "greeting.txt")
        #expect(fileStat["size"] as? Int == 14)
        #expect((fileStat["mode"] as? Int).map { UInt32($0) & 0o777 } == 0o755)

        let directory = try await h.request("GET", "/containers/box/archive?path=/tmp/sub")
        #expect(try Self.tarEntries(directory.body) == ["sub": "/", "sub/inner.txt": "nested\n"])
        #expect((try Self.stat(directory)["mode"] as? Int).map { UInt32($0) & (1 << 31) } == 1 << 31)
        // Every scratch copy is gone once its answer has been sent.
        #expect(await StreamHarness.eventually { ((try? FileManager.default.contentsOfDirectory(atPath: h.tools.scratch.path)) ?? ["?"]).isEmpty })
    }

    @Test("HEAD answers the stat header alone, from stat in the container, with a link's target")
    func head() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "etc"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: h.tools.root.appending(path: "etc/real"))
        try FileManager.default.createSymbolicLink(atPath: h.tools.root.appending(path: "etc/link").path, withDestinationPath: "real")
        let answer = try await h.request("HEAD", "/containers/box/archive?path=/etc/link")
        #expect(answer.status == 200)
        #expect(answer.body.isEmpty)
        let stat = try Self.stat(answer)
        #expect(stat["linkTarget"] as? String == "real")
        #expect((stat["mode"] as? Int).map { UInt32($0) & (1 << 27) } == 1 << 27)
        // No copy was made for it.
        #expect(h.tools.copyCalls.isEmpty)
    }

    @Test("an image without stat still answers HEAD and GET, from the copy")
    func withoutStat() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.available.remove("stat")
        try Data("abc".utf8).write(to: h.tools.root.appending(path: "f"))
        let answer = try await h.request("HEAD", "/containers/box/archive?path=/f")
        #expect(try Self.stat(answer)["size"] as? Int == 3)
        let root = try await h.request("HEAD", "/containers/box/archive?path=/")
        #expect((try Self.stat(root)["mode"] as? Int).map { UInt32($0) & (1 << 31) } == 1 << 31)
        #expect(try Self.tarEntries(try await h.request("GET", "/containers/box/archive?path=/f").body) == ["f": "abc"])
        // A missing path is still a 404, from the copy that found nothing.
        #expect(try await h.request("GET", "/containers/box/archive?path=/nope").status == 404)
    }

    @Test("missing paths, a file as the extraction point, a stopped container, no path and a compressed upload are refused")
    func refusals() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        let missing = try await h.request("GET", "/containers/box/archive?path=/nope")
        #expect(missing.status == 404)
        #expect(try missing.json()["message"] as? String == "Could not find the file /nope in container box")
        #expect(try await h.request("HEAD", "/containers/box/archive?path=/nope").status == 404)
        try Data("x".utf8).write(to: h.tools.root.appending(path: "file"))
        var tar = TarBuilder()
        tar.file("a", "a")
        let notDirectory = try await h.request("PUT", "/containers/box/archive?path=/file", body: tar.archive)
        #expect(notDirectory.status == 400)
        #expect(try notDirectory.json()["message"] as? String == "extraction point is not a directory")
        #expect(try await h.request("PUT", "/containers/box/archive?path=/nope", body: tar.archive).status == 404)
        #expect(try await h.request("GET", "/containers/off/archive?path=/").status == 409)
        // An upload before the start, as Testcontainers sends it, says why it is refused.
        let beforeStart = try await h.request("PUT", "/containers/off/archive?path=%2F&noOverwriteDirNonDir=false&copyUIDGID=false", body: tar.archive)
        #expect(beforeStart.status == 409)
        #expect((try beforeStart.json()["message"] as? String)?.hasSuffix("copies files into a running container only, so start it first") == true)
        #expect(h.tools.copyCalls.isEmpty)
        let noPath = try await h.request("GET", "/containers/box/archive")
        #expect(try noPath.json()["message"] as? String == "bad parameter: path cannot be empty")
        let gzip: [UInt8] = [0x1F, 0x8B, 8, 0] + [UInt8](repeating: 0, count: 600)
        #expect(try await h.request("PUT", "/containers/box/archive?path=/", body: gzip).status == 400)
        // Control: the same archive uncompressed goes in.
        #expect(try await h.request("PUT", "/containers/box/archive?path=/", body: tar.archive).status == 200)
    }

    @Test("an upload that tries to leave its directory is refused before anything is copied in")
    func hostileUpload() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        var tar = TarBuilder()
        tar.file("fine.txt", "ok")
        tar.file("../escape", "pwned")
        let answer = try await h.request("PUT", "/containers/box/archive?path=/", body: tar.archive)
        #expect(answer.status == 400)
        #expect(h.tools.copyCalls.isEmpty)
    }

    @Test("noOverwriteDirNonDir refuses replacing a directory with a file; without it the copy goes ahead")
    func noOverwrite() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "data/thing"), withIntermediateDirectories: true)
        var tar = TarBuilder()
        tar.file("thing", "now a file")
        let refused = try await h.request("PUT", "/containers/box/archive?path=/data&noOverwriteDirNonDir=1", body: tar.archive)
        #expect(refused.status == 500)
        #expect((try refused.json()["message"] as? String)?.hasPrefix("cannot overwrite directory") == true)
        #expect(try await h.request("PUT", "/containers/box/archive?path=/data", body: tar.archive).status == 200)
    }

    @Test("an upload larger than the server's in-memory limit is spooled; past the route's own bound it is a 413")
    func spooledUpload() async throws {
        let spool = FileManager.default.temporaryDirectory.appending(path: "dapi-spool-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spool) }
        let h = try await ToolHarness.start(
            options: DockerToolOptions(maxUploadBytes: 64 << 10), limits: DockerHTTPLimits(maxBodyBytes: 4 << 10, spoolDirectory: spool))
        defer { Task { try? await h.stop() } }
        var tar = TarBuilder()
        tar.file("big", String(repeating: "z", count: 20 << 10))
        #expect(tar.archive.count > 4 << 10)
        let accepted = try await h.request("PUT", "/containers/box/archive?path=/", body: tar.archive)
        #expect(accepted.status == 200)
        #expect((try? Data(contentsOf: h.tools.root.appending(path: "big")))?.count == 20 << 10)
        var huge = TarBuilder()
        huge.file("huge", String(repeating: "z", count: 80 << 10))
        #expect(try await h.request("PUT", "/containers/box/archive?path=/", body: huge.archive).status == 413)
        // The spooled bodies are gone once answered, the refused one included.
        #expect(await StreamHarness.eventually { ((try? FileManager.default.contentsOfDirectory(atPath: spool.path)) ?? ["?"]).isEmpty })
        // Control: a route that does not spool keeps the in-memory limit.
        let body = Array(String(repeating: "x", count: 8 << 10).utf8)
        #expect(try await h.request("POST", "/containers/box/exec", body: body).status == 413)
    }
}
