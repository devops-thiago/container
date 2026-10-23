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
import Foundation
import NIOCore
import Synchronization
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

    /// A header with `size` in its octal field and nothing after it.
    mutating func header(_ name: String, type: DockerTar.EntryType, size: UInt64, link: String = "") {
        bytes += DockerTar.ustar(name: name, prefix: "", type: type, mode: 0o644, size: size, mtime: Fixtures.now, link: link)
    }

    /// A header whose 12-byte size field is `field` as it is, with nothing after it.
    mutating func header(_ name: String, type: DockerTar.EntryType, sizeField field: [UInt8], link: String = "") {
        var block = DockerTar.ustar(name: name, prefix: "", type: type, mode: 0o644, size: 0, mtime: Fixtures.now, link: link)
        block.replaceSubrange(124..<136, with: field)
        Self.checksum(&block)
        bytes += block
    }

    /// A file whose header names `uid` and `gid` as its owner.
    mutating func file(_ name: String, _ content: String, uid: UInt32, gid: UInt32) {
        let data = Array(content.utf8)
        var block = DockerTar.ustar(name: name, prefix: "", type: .file, mode: 0o644, size: UInt64(data.count), mtime: Fixtures.now, link: "")
        for (offset, id) in [(108, uid), (116, gid)] {
            let digits = String(id, radix: 8)
            let field = Array((String(repeating: "0", count: max(7 - digits.count, 0)) + digits).utf8) + [0]
            block.replaceSubrange(offset..<offset + 8, with: field)
        }
        Self.checksum(&block)
        bytes += block + data + DockerTar.padding(data.count)
    }

    /// A pax extended header holding `records` as they are: for the next entry, or with
    /// `global`, a global one.
    mutating func pax(_ records: [UInt8], global: Bool = false) {
        bytes += DockerTar.ustar(
            name: global ? "GlobalHead.0.0" : "PaxHeaders/x", prefix: "", type: global ? .paxGlobal : .paxExtended, mode: 0o644,
            size: UInt64(records.count), mtime: Fixtures.now, link: "")
        bytes += records + DockerTar.padding(records.count)
    }

    /// GNU's base-256 encoding of `value` in a 12-byte field.
    static func base256(_ value: UInt64) -> [UInt8] {
        [0x80, 0, 0, 0] + (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) }
    }

    /// Writes a block's checksum again after a change to it.
    static func checksum(_ block: inout [UInt8]) {
        for index in 148..<156 { block[index] = UInt8(ascii: " ") }
        let digits = String(block.reduce(0) { $0 + Int($1) }, radix: 8)
        for (index, byte) in (String(repeating: "0", count: max(6 - digits.count, 0)) + digits).utf8.enumerated() { block[148 + index] = byte }
        block[154] = 0
        block[155] = UInt8(ascii: " ")
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

    @Test("each entry keeps the owner its header names, from ustar's fields or a pax record; an implied directory is root's")
    func owners() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.file("a/owned.txt", "owned\n", uid: 1234, gid: 4321)
        tar.pax(DockerTar.paxRecords([("uid", "70000"), ("gid", "70001")]))
        tar.directory("b")
        tar.file("plain.txt", "plain\n")
        _ = try scratch.extract(tar.archive)
        let root = scratch.root.path
        #expect(CopyOwner.recorded(at: root + "/a") == CopyOwner(uid: 0, gid: 0))
        #expect(CopyOwner.recorded(at: root + "/a/owned.txt") == CopyOwner(uid: 1234, gid: 4321))
        #expect(CopyOwner.recorded(at: root + "/b") == CopyOwner(uid: 70000, gid: 70001))
        #expect(CopyOwner.recorded(at: root + "/plain.txt") == CopyOwner(uid: 0, gid: 0))

        var huge = TarBuilder()
        huge.pax(DockerTar.paxRecords([("uid", "4294967296")]))
        huge.file("x", "x\n")
        #expect(throws: DockerTarRejection.self) { try Scratch().extract(huge.archive) }
    }

    @Test("a global pax header's owner applies to no entry, as dockerd ignores the header; its records must still parse")
    func globalPaxOwnerIgnored() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.pax(DockerTar.paxRecords([("uid", "1234"), ("gid", "5678")]), global: true)
        tar.file("plain.txt", "plain\n")
        tar.file("owned.txt", "owned\n", uid: 42, gid: 43)
        // A per-entry header before a global one belongs to the global one, as Go reads it.
        tar.pax(DockerTar.paxRecords([("uid", "70000"), ("path", "elsewhere.txt")]))
        tar.pax(DockerTar.paxRecords([("comment", "x")]), global: true)
        tar.file("last.txt", "last\n")
        let entries = try scratch.extract(tar.archive)
        let root = scratch.root.path
        #expect(entries.map(\.name).sorted() == ["last.txt", "owned.txt", "plain.txt"])
        #expect(CopyOwner.recorded(at: root + "/plain.txt") == CopyOwner(uid: 0, gid: 0))
        #expect(CopyOwner.recorded(at: root + "/owned.txt") == CopyOwner(uid: 42, gid: 43))
        #expect(CopyOwner.recorded(at: root + "/last.txt") == CopyOwner(uid: 0, gid: 0))

        var malformed = TarBuilder()
        malformed.pax(Array("99 uid=1\n".utf8), global: true)
        malformed.file("x", "x\n")
        #expect(throws: DockerTarRejection.self) { try Scratch().extract(malformed.archive) }
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

    @Test("a pax record's length must be decimal digits reaching past its space to its newline, and it must have a key and an equals sign")
    func paxRecordLengths() throws {
        // A length that stops at or before the space, runs past the header or is not digits; a
        // record without its newline; a record without a key.
        for record in ["1 ", "01 ", "2 ", "3 \n", "0 a=\n", "9 a=\n", "+6 a=\n", " a=\n", "5 a=x", "6 ab=x\n", "3 a\n", "4 =\n"] {
            #expect(throws: DockerTarRejection.self, "\(record.debugDescription)") { try DockerTarExtractor.paxRecords(Array(record.utf8)) }
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.pax(Array(record.utf8))
            tar.file("after.txt", "x")
            #expect(throws: DockerTarRejection.self, "\(record.debugDescription)") { try scratch.extract(tar.archive) }
            #expect(scratch.leaked.isEmpty)
            #expect(scratch.contents("after.txt") == nil)
        }
        // Control: what the writer makes, an unknown key among them, a value with its own `=`,
        // and an empty value.
        let long = String(repeating: "p", count: 300)
        let records = try DockerTarExtractor.paxRecords(DockerTar.paxRecords([("path", long), ("linkpath", "../t"), ("size", "12"), ("comment", "a=b")]))
        #expect(records == ["path": long, "linkpath": "../t", "size": "12", "comment": "a=b"])
        #expect(try DockerTarExtractor.paxRecords(Array("6 ab=\n".utf8)) == ["ab": ""])
    }

    @Test("a size no header can carry is refused: base-256 past Int64.max or negative, and a pax size past it")
    func sizesPastInt64() throws {
        let fields: [(String, [UInt8])] = [
            ("UInt64.max", TarBuilder.base256(UInt64.max)), ("UInt64.max - 511", TarBuilder.base256(UInt64.max - 511)),
            ("2^63", TarBuilder.base256(UInt64(1) << 63)), ("-1", [UInt8](repeating: 0xFF, count: 12)),
        ]
        for (name, field) in fields {
            for type in [DockerTar.EntryType.directory, .symlink, .hardLink, .file] {
                let scratch = try Scratch()
                var tar = TarBuilder()
                tar.file("t", "target")
                tar.header("e", type: type, sizeField: field, link: "t")
                #expect(throws: DockerTarRejection.self, "\(name) on \(type)") { try scratch.extract(tar.archive) }
                #expect(scratch.leaked.isEmpty)
            }
        }
        for size in ["18446744073709551615", "9223372036854775808", "-1", "", "x"] {
            let scratch = try Scratch()
            var tar = TarBuilder()
            tar.pax(DockerTar.paxRecords([("size", size)]))
            tar.directory("d")
            #expect(throws: DockerTarRejection.self, "\(size)") { try scratch.extract(tar.archive) }
        }
        // Control: Int64.max itself is a number, which a directory ignores and a file cannot hold.
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.header("d/", type: .directory, sizeField: TarBuilder.base256(UInt64(Int64.max)))
        tar.file("d/f", "f")
        #expect(try scratch.extract(tar.archive).map(\.name) == ["d"])
        #expect(scratch.contents("d/f") == "f")
        var file = TarBuilder()
        file.header("f", type: .file, sizeField: TarBuilder.base256(UInt64(Int64.max)))
        let other = try Scratch()
        #expect(throws: DockerTarRejection.self) { try other.extract(file.archive) }
    }

    @Test("a directory's or a link's size field is not a body, as Go's archive/tar reads it: the next header follows at once")
    func headerOnlySizes() throws {
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.header("d/", type: .directory, size: 4096)
        tar.file("d/f", "inside")
        tar.file("t", "target")
        tar.header("l", type: .symlink, size: 0o77777777777, link: "t")
        tar.header("h", type: .hardLink, size: 7, link: "t")
        tar.pax(DockerTar.paxRecords([("size", "9223372036854775807")]))
        tar.directory("e")
        tar.header("./", type: .directory, size: 4096)
        tar.file("last", "last")
        let entries = try scratch.extract(tar.archive)
        #expect(entries.map(\.name) == ["d", "t", "l", "h", "e", "last"])
        #expect(scratch.contents("d/f") == "inside")
        #expect(scratch.contents("l") == "target")
        #expect(scratch.contents("h") == "target")
        #expect(scratch.contents("last") == "last")
        #expect(scratch.leaked.isEmpty)
    }

    @Test("a body the archive ends before is refused, the root entry's included")
    func bodiesPastTheEnd() throws {
        // A file, and the root entry as a file, each claiming more than follows.
        for (name, type) in [("f", DockerTar.EntryType.file), ("./", .file), ("./", .contiguous)] {
            for size: UInt64 in [4096, UInt64(Int64.max) - 511, UInt64(Int64.max)] {
                let scratch = try Scratch()
                var tar = TarBuilder()
                tar.header(name, type: type, sizeField: TarBuilder.base256(size))
                tar.bytes += [UInt8](repeating: 0, count: 1024)
                #expect(throws: DockerTarRejection.self, "\(name) \(size)") { try scratch.extract(tar.archive) }
                #expect(scratch.leaked.isEmpty)
            }
        }
        // Control: a root entry whose body is there is passed over, and what follows is read.
        let scratch = try Scratch()
        var tar = TarBuilder()
        tar.header("./", type: .file, size: 1000)
        tar.bytes += [UInt8](repeating: UInt8(ascii: "r"), count: 1000) + DockerTar.padding(1000)
        tar.file("after", "after")
        #expect(try scratch.extract(tar.archive).map(\.name) == ["after"])
        #expect(scratch.contents("after") == "after")
    }

    @Test("a NUL in a name or a link target is refused: the calls that make the entry would stop at it")
    func nulInNames() throws {
        var climbing = TarBuilder()
        climbing.pax(DockerTar.paxRecords([("path", "..\u{0}/escape")]))
        climbing.file("x", "x")
        var inner = TarBuilder()
        inner.pax(DockerTar.paxRecords([("path", "a\u{0}b")]))
        inner.directory("d")
        var links = TarBuilder()
        links.file("t", "t")
        links.pax(DockerTar.paxRecords([("linkpath", "t\u{0}/../../x")]))
        links.symlink("l", to: "t")
        var hard = TarBuilder()
        hard.file("t", "t")
        hard.pax(DockerTar.paxRecords([("linkpath", "t\u{0}")]))
        hard.hardLink("h", to: "t")
        for (name, tar) in [("path", climbing), ("inner", inner), ("linkpath", links), ("hard link", hard)] {
            let scratch = try Scratch()
            #expect(throws: DockerTarRejection.self, "\(name)") { try scratch.extract(tar.archive) }
            #expect(scratch.leaked.isEmpty, "\(name)")
        }
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

    @Test("stat -c '%f %s %Y %u %g' output reads as a stat with its owner; without the owner's fields it has none; anything else is not a stat")
    func parseStat() {
        #expect(DockerPathStat.statFormat == "%f %s %Y %u %g")
        let stat = DockerPathStat.parse(statOutput: "41ed 4096 1800000000 1000 1001\n", name: "etc")
        #expect(stat?.isDirectory == true)
        #expect(stat?.size == 4096)
        #expect(stat?.mtime == Fixtures.now)
        #expect(stat?.owner == CopyOwner(uid: 1000, gid: 1001))
        #expect(DockerPathStat.parse(statOutput: "41ed 4096 1800000000\n", name: "etc")?.owner == nil)
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

    @Test("PUT keeps on each staged entry the owner its header names, and passes copyUIDGID on", arguments: [false, true])
    func uploadOwners(copyUIDGID: Bool) async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "tmp"), withIntermediateDirectories: true)
        var tar = TarBuilder()
        tar.file("owned.txt", "owned\n", uid: 1234, gid: 4321)
        tar.pax(DockerTar.paxRecords([("uid", "70000"), ("gid", "70001")]))
        tar.file("big-ids.txt", "pax\n")
        let put = try await h.request(
            "PUT", "/containers/box/archive?path=/tmp&copyUIDGID=\(copyUIDGID)", body: tar.archive, contentType: "application/x-tar")
        #expect(put.status == 200)
        let flag = copyUIDGID ? " copyUIDGID" : ""
        #expect(h.tools.copyCalls == ["in owned.txt /tmp 644\(flag)", "in big-ids.txt /tmp 644\(flag)"])
        #expect(h.tools.copyOwnerCalls == [CopyOwner(uid: 1234, gid: 4321), CopyOwner(uid: 70000, gid: 70001)])
    }

    @Test("an upload held for a start keeps copyUIDGID for it")
    func heldUploadKeepsCopyUIDGID() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        var tar = TarBuilder()
        tar.file("hello.txt", "hello\n")
        #expect(try await h.request("PUT", "/containers/off/archive?path=/data&copyUIDGID=true", body: tar.archive).status == 200)
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        #expect(h.tools.copyCalls == ["in hello.txt /data 644 copyUIDGID"])
        #expect(h.tools.copyOwnerCalls == [CopyOwner(uid: 0, gid: 0)])
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

    @Test("GET gives each entry its own numeric owner in the container, as dockerd's archive does")
    func downloadOwners() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        try FileManager.default.createDirectory(at: h.tools.root.appending(path: "srv"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: h.tools.root.appending(path: "srv/f"))
        h.tools.with { $0.owners = ["/srv": CopyOwner(uid: 101, gid: 102), "/srv/f": CopyOwner(uid: 1234, gid: 5678)] }
        let body = try await h.request("GET", "/containers/box/archive?path=/srv").body
        // The directory's header, then the file's.
        #expect(DockerTarExtractor.ustarName(Array(body[0..<512])) == "srv/")
        #expect(try DockerTarExtractor.number(body[108..<116]) == 101)
        #expect(try DockerTarExtractor.number(body[116..<124]) == 102)
        #expect(DockerTarExtractor.ustarName(Array(body[512..<1024])) == "srv/f")
        #expect(try DockerTarExtractor.number(body[620..<628]) == 1234)
        #expect(try DockerTarExtractor.number(body[628..<636]) == 5678)
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

    /// What the routes left on disk: in the scratch directory, being written for a hold, and
    /// held for a start.
    static func scratchEntries(_ h: ToolHarness) -> [String] {
        let scratch = (try? FileManager.default.contentsOfDirectory(atPath: h.tools.scratch.path)) ?? ["?"]
        let queue = h.tools.queue.directory
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: queue.appending(path: "staging").path)) ?? []
        let pending = queue.appending(path: "pending")
        let held = ((try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? []).flatMap { container in
            (try? FileManager.default.contentsOfDirectory(atPath: pending.appending(path: container).path)) ?? []
        }
        return scratch + staging + held
    }

    @Test("a stopped-container upload records its requested no-overwrite policy")
    func heldNoOverwritePolicy() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        var tar = TarBuilder()
        tar.file("entry", "keep type")
        #expect(try await h.request("PUT", "/containers/off/archive?path=/&noOverwriteDirNonDir=true", body: tar.archive).status == 200)
        let queue = try #require(h.streams.copies.queue)
        let id = String(ToolHarness.stoppedID.prefix(12))
        try queue.claim(id)
        let seen = Mutex<[Bool]>([])
        try await queue.apply(id) { _, _, _, _, noOverwrite, _ in seen.withLock { $0.append(noOverwrite) } }
        #expect(seen.withLock { $0 } == [true])
    }

    @Test("an upload into a container that is not running is held, and copied in at its start before its process runs")
    func uploadBeforeStart() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        // What Testcontainers' withCopyToContainer sends: one file named by its whole path under
        // the root, with no entry for its directory, uploaded to path=/.
        var tar = TarBuilder()
        tar.file("smoke/hello.txt", "hello from the host\n", mode: 0o640)
        let put = try await h.request(
            "PUT", "/containers/off/archive?path=%2F&noOverwriteDirNonDir=false&copyUIDGID=false", body: tar.archive, contentType: "application/x-tar")
        #expect(put.status == 200)
        // Nothing reaches the container yet: there is none to reach.
        #expect(h.tools.copyCalls.isEmpty)
        #expect(Self.scratchEntries(h).count == 1)
        #expect(h.streams.copies.holds(String(ToolHarness.stoppedID.prefix(12))))

        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        #expect(h.tools.copyCalls == ["in smoke / 755"])
        // The directory the archive only implies is root's, as dockerd makes it.
        #expect(h.tools.copyOwnerCalls == [CopyOwner(uid: 0, gid: 0)])
        // Bootstrapped, not yet started: the process sees the files from its first instruction.
        #expect(h.tools.copyInStatusCalls == [.stopped])
        #expect(try String(contentsOf: h.tools.root.appending(path: "smoke/hello.txt"), encoding: .utf8) == "hello from the host\n")
        #expect(await StreamHarness.eventually { Self.scratchEntries(h).isEmpty })
        #expect(!h.streams.copies.holds(String(ToolHarness.stoppedID.prefix(12))))
    }

    @Test("an engine that cannot copy before a start still refuses an upload into a container that is not running")
    func uploadBeforeStartUnsupported() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        var tar = TarBuilder()
        tar.file("hello.txt", "x")
        let put = try await h.request("PUT", "/containers/off/archive?path=/", body: tar.archive)
        #expect(put.status == 409)
        #expect((try put.json()["message"] as? String)?.hasSuffix("copies files into a running container only, so start it first") == true)
        #expect(Self.scratchEntries(h).isEmpty)
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        #expect(h.tools.copyCalls.isEmpty)
    }

    @Test("a held upload that cannot be copied in fails the start and stays held for the next; a removed container's held upload is dropped")
    func heldUploadFailureAndRemoval() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with {
            $0.copyBeforeStart = true
            $0.copyInError = DockerAPIError.internalError("disk full")
        }
        var tar = TarBuilder()
        tar.file("hello.txt", "x")
        #expect(try await h.request("PUT", "/containers/off/archive?path=/data", body: tar.archive).status == 200)
        let failed = try await h.request("POST", "/containers/off/start")
        #expect(failed.status == 500)
        #expect((try failed.json()["message"] as? String)?.contains("could not copy hello.txt into /data before the start: disk full") == true)
        #expect(Self.scratchEntries(h).count == 1)
        // Started again, it goes in.
        #expect(try await h.request("POST", "/containers/off/start").status == 204)
        #expect(h.tools.copyCalls == ["in hello.txt /data 644", "in hello.txt /data 644"])
        #expect(await StreamHarness.eventually { Self.scratchEntries(h).isEmpty })
        _ = try await h.request("POST", "/containers/off/stop?t=0")

        #expect(try await h.request("PUT", "/containers/off/archive?path=/", body: tar.archive).status == 200)
        #expect(Self.scratchEntries(h).count == 1)
        #expect(try await h.request("DELETE", "/containers/off?force=1").status == 204)
        #expect(Self.scratchEntries(h).isEmpty)
    }

    @Test("an upload held for a start gets the same guards: names that climb, links that point out, devices and the bounds")
    func heldUploadGuards() async throws {
        let h = try await ToolHarness.start(options: DockerToolOptions(maxUploadBytes: 8 << 10, maxUploadEntries: 4))
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        var climbing = TarBuilder()
        climbing.file("fine.txt", "ok")
        climbing.file("../escape", "pwned")
        var linkOut = TarBuilder()
        linkOut.symlink("etc", to: "/etc")
        var device = TarBuilder()
        device.entry("dev", type: .characterDevice)
        var big = TarBuilder()
        big.file("big", String(repeating: "z", count: 16 << 10))
        var many = TarBuilder()
        for index in 0..<6 { many.file("f\(index)", "x") }
        for (name, tar) in [("climbing", climbing), ("link out", linkOut), ("device", device), ("too big", big), ("too many", many)] {
            let answer = try await h.request("PUT", "/containers/off/archive?path=/", body: tar.archive)
            #expect([400, 413].contains(answer.status), "\(name)")
        }
        // Nothing was held, and nothing is left in the scratch directory.
        #expect(!h.streams.copies.holds(String(ToolHarness.stoppedID.prefix(12))))
        #expect(Self.scratchEntries(h).isEmpty)
        // Control: a small upload of a plain file is held.
        var plain = TarBuilder()
        plain.file("ok.txt", "ok")
        #expect(try await h.request("PUT", "/containers/off/archive?path=/", body: plain.archive).status == 200)
        #expect(h.streams.copies.holds(String(ToolHarness.stoppedID.prefix(12))))
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

    /// The archives that stopped the service before the parser checked them: a pax record
    /// whose length stops at its space, and sizes no header can carry on a directory.
    static var malformed: [(String, [UInt8])] {
        var short = TarBuilder()
        short.pax(Array("1 ".utf8))
        short.directory("d")
        var leadingZero = TarBuilder()
        leadingZero.pax(Array("01 ".utf8))
        leadingZero.directory("d")
        var max = TarBuilder()
        max.header("d/", type: .directory, sizeField: TarBuilder.base256(UInt64.max))
        var nearMax = TarBuilder()
        nearMax.header("d/", type: .directory, sizeField: TarBuilder.base256(UInt64.max - 511))
        var paxSize = TarBuilder()
        paxSize.pax(DockerTar.paxRecords([("size", "18446744073709551615")]))
        paxSize.directory("d")
        return [
            ("pax length 1", short.archive), ("pax length 01", leadingZero.archive), ("base-256 UInt64.max", max.archive),
            ("base-256 UInt64.max - 511", nearMax.archive), ("pax size UInt64.max", paxSize.archive),
        ]
    }

    @Test("a malformed archive is a 400 in words, into a running container or one waiting for a start, and the service goes on")
    func malformedUploads() async throws {
        let h = try await ToolHarness.start()
        defer { Task { try? await h.stop() } }
        h.tools.with { $0.copyBeforeStart = true }
        for (name, archive) in Self.malformed {
            for container in ["box", "off"] {
                let answer = try await h.request("PUT", "/containers/\(container)/archive?path=/", body: archive, contentType: "application/x-tar")
                #expect(answer.status == 400, "\(name) into \(container)")
                let message = try answer.json()["message"] as? String
                #expect(message?.hasPrefix("invalid ") == true, "\(name) into \(container): \(message ?? "")")
            }
        }
        #expect(h.tools.copyCalls.isEmpty)
        #expect(!h.streams.copies.holds(String(ToolHarness.stoppedID.prefix(12))))
        #expect(await StreamHarness.eventually { Self.scratchEntries(h).isEmpty })
        // Control: the same service takes a well-formed upload after them.
        var tar = TarBuilder()
        tar.file("ok.txt", "ok")
        #expect(try await h.request("PUT", "/containers/box/archive?path=/", body: tar.archive).status == 200)
        #expect(h.tools.copyCalls == ["in ok.txt / 644"])
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
