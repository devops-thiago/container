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

import Compression
import Darwin
import Foundation
import zlib

/// How much of a build context `POST /build` takes.
public struct DockerBuildLimits: Sendable {
    /// The largest request body: the context as the client sent it, compressed or not.
    public var maxBodyBytes: Int
    /// The most the context may hold once decompressed, and in its files once unpacked.
    public var maxContextBytes: Int
    /// The most entries the context's archive may have.
    public var maxEntries: Int

    public init(maxBodyBytes: Int = 8 << 30, maxContextBytes: Int = 8 << 30, maxEntries: Int = 1 << 20) {
        self.maxBodyBytes = maxBodyBytes
        self.maxContextBytes = maxContextBytes
        self.maxEntries = maxEntries
    }
}

/// A build context as `POST /build` receives it, made ready for the builder: decompressed,
/// unpacked into a directory of its own, and its Dockerfile found.
///
/// The body is a tar, optionally gzip- or xz-compressed, as the Docker CLI sends it (`--compress`
/// gzips it). A body that is not a tar is a Dockerfile on its own, with no context. The archive
/// is unpacked by `DockerTarExtractor`, which refuses anything that would land outside the
/// directory.
struct DockerBuildContext {
    /// The compression a body arrived with, read from its first bytes.
    enum Encoding: String, Equatable {
        case identity
        case gzip
        case bzip2
        case xz
        case zstd
    }

    /// What dockerd names the Dockerfile when the client names none.
    static let defaultDockerfile = "Dockerfile"

    /// The largest Dockerfile a build takes, as `container build` takes it: smaller than this.
    /// The same bound and words as `Builder.checkBuildFileSize`, which a test holds them to; see
    /// https://github.com/apple/container/issues/735.
    static let maxDockerfileBytes = 16 * 1024

    /// The directory holding the context, made for this build alone.
    let context: URL
    /// The name the Dockerfile was found under, relative to the context.
    let dockerfileName: String
    let dockerfile: Data
    /// The context's `.dockerignore`, when it has one.
    let dockerignore: Data?

    /// Prepares the body at `body` in `directory`, which must exist and be empty and which the
    /// caller removes, whatever happens.
    static func prepare(body: URL, dockerfile requested: String, in directory: URL, limits: DockerBuildLimits) throws(DockerAPIError) -> Self {
        let context = directory.appending(path: "context", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: false)
        } catch {
            throw .internalError("could not make a directory for the build context: \(error)")
        }
        var archive = body
        let encoding = try Self.encoding(of: body)
        switch encoding {
        case .identity:
            break
        case .gzip, .xz:
            archive = directory.appending(path: "context.tar")
            try decompress(body, encoding: encoding, to: archive, maxBytes: limits.maxContextBytes)
        case .bzip2, .zstd:
            throw .badRequest(
                "a \(encoding.rawValue)-compressed build context is not supported by SiliconShip: send it uncompressed, or gzip- or xz-compressed")
        }

        guard try isTar(archive) else {
            // A Dockerfile on its own: the whole body is it, whatever name was asked for.
            let data = try read(archive, limit: maxDockerfileBytes)
            try checkSize(data.size)
            return Self(context: context, dockerfileName: defaultDockerfile, dockerfile: data.bytes, dockerignore: nil)
        }
        do {
            _ = try DockerTarExtractor(maxBytes: limits.maxContextBytes, maxEntries: limits.maxEntries).extract(archive, into: context)
        } catch let rejection as DockerTarRejection {
            throw .badRequest("invalid build context: \(rejection.message)")
        } catch {
            throw .internalError("could not unpack the build context: \(error)")
        }
        if archive != body {
            // The decompressed copy is not needed once unpacked.
            try? FileManager.default.removeItem(at: archive)
        }
        let (name, file) = try locateDockerfile(requested, in: context)
        let dockerfile = try read(file, limit: maxDockerfileBytes)
        try checkSize(dockerfile.size)
        let ignore = try? regularFile(".dockerignore", in: context)
        let dockerignore = try ignore.flatMap { file throws(DockerAPIError) in try read(file, limit: limits.maxContextBytes).bytes }
        return Self(context: context, dockerfileName: name, dockerfile: dockerfile.bytes, dockerignore: dockerignore)
    }

    /// Refuses a Dockerfile of `maxDockerfileBytes` or more, in `container build`'s words.
    static func checkSize(_ size: Int) throws(DockerAPIError) {
        guard size < maxDockerfileBytes else { throw .badRequest(tooLarge(size)) }
    }

    /// `container build`'s refusal of a Dockerfile of `size` bytes.
    static func tooLarge(_ size: Int) -> String {
        "Dockerfile size (\(size) bytes) exceeds the maximum allowed size of \(maxDockerfileBytes) bytes. "
            + "See https://github.com/apple/container/issues/735."
    }

    // MARK: - Dockerfile

    /// Finds the Dockerfile `requested` names in `context`, as dockerd finds it: by its path in
    /// the context, and when that is the default `Dockerfile` and missing, as `dockerfile`.
    /// That includes the `.dockerfile.<random>` the CLI adds for a Dockerfile from outside the
    /// context.
    static func locateDockerfile(_ requested: String, in context: URL) throws(DockerAPIError) -> (name: String, file: URL) {
        let name = requested.isEmpty ? defaultDockerfile : requested
        if let file = try regularFile(name, in: context) { return (name, file) }
        if name == defaultDockerfile, let file = try regularFile(name.lowercased(), in: context) {
            return (name.lowercased(), file)
        }
        // dockerd's words and status (500: its error carries no type), which the CLI prints
        // after "Error response from daemon:".
        throw .internalError("Cannot locate specified Dockerfile: \(name)")
    }

    /// The regular file at `name` in `context`, or nil when there is none. A name that climbs
    /// out of the context, or a link that resolves outside it, is refused.
    static func regularFile(_ name: String, in context: URL) throws(DockerAPIError) -> URL? {
        let components = name.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !name.hasPrefix("/"), !components.contains("..") else {
            throw .badRequest("the Dockerfile path \(name) must be inside the build context")
        }
        guard !components.isEmpty else { return nil }
        let root = context.path(percentEncoded: false)
        // Names match as they would on the Linux host a Docker daemon runs on: exactly, case
        // included, though this volume may not care about case.
        var parent = root
        for component in components.map(String.init) {
            guard (try? FileManager.default.contentsOfDirectory(atPath: parent))?.contains(component) == true else { return nil }
            parent += "/" + component
        }
        guard let realRoot = realPath(root) else { return nil }
        guard let real = realPath(parent) else { return nil }
        guard real.hasPrefix(realRoot + "/") else {
            throw .badRequest("the Dockerfile path \(name) must be inside the build context")
        }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return URL(fileURLWithPath: real)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The file's size, and its bytes when it is smaller than `limit`; a larger one is not read.
    static func read(_ file: URL, limit: Int) throws(DockerAPIError) -> (size: Int, bytes: Data) {
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? NSNumber)?.intValue ?? 0
            guard size < limit else { return (size, Data()) }
            return (size, try Data(contentsOf: file))
        } catch {
            throw .internalError("could not read \(file.lastPathComponent) from the build context: \(error)")
        }
    }

    // MARK: - Body

    /// The compression `file` starts with: gzip, bzip2, xz and zstd by their magic numbers,
    /// as dockerd detects them; anything else is taken as it is.
    static func encoding(of file: URL) throws(DockerAPIError) -> Encoding {
        let prefix: [UInt8]
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            prefix = Array(try handle.read(upToCount: 6) ?? Data())
        } catch {
            throw .internalError("could not read the build context: \(error)")
        }
        func starts(_ magic: [UInt8]) -> Bool { prefix.starts(with: magic) }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts([0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        return .identity
    }

    /// Whether `file` is a tar: its first block is a whole header with a valid checksum. An
    /// empty file is an archive with nothing in it.
    static func isTar(_ file: URL) throws(DockerAPIError) -> Bool {
        let block: [UInt8]
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            block = Array(try handle.read(upToCount: DockerTar.blockSize) ?? Data())
        } catch {
            throw .internalError("could not read the build context: \(error)")
        }
        if block.isEmpty { return true }
        guard block.count == DockerTar.blockSize else { return false }
        return block.allSatisfy { $0 == 0 } || DockerTarExtractor.checksumMatches(block)
    }

    /// Decompresses `source` into a new file at `destination`, refusing more than `maxBytes`
    /// of output and a stream that is cut short or corrupt.
    static func decompress(_ source: URL, encoding: Encoding, to destination: URL, maxBytes: Int) throws(DockerAPIError) {
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let fd = open(destination.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var sink = Sink(fd: fd, maxBytes: maxBytes)
            switch encoding {
            case .gzip:
                try gunzip(input, into: &sink)
            case .xz:
                try unxz(input, into: &sink)
            default:
                throw DockerAPIError.internalError("cannot decompress \(encoding.rawValue)")
            }
        } catch let error as DockerAPIError {
            throw error
        } catch {
            throw .internalError("could not decompress the build context: \(error)")
        }
    }

    static let chunkSize = 1 << 16

    /// Where decompressed bytes go, counted against the bound.
    struct Sink {
        let fd: Int32
        let maxBytes: Int
        var written = 0

        mutating func write(_ bytes: UnsafePointer<UInt8>, count: Int) throws {
            guard count > 0 else { return }
            written += count
            guard written <= maxBytes else {
                throw DockerAPIError(.payloadTooLarge, "the build context is larger than \(maxBytes) bytes once decompressed")
            }
            var offset = 0
            while offset < count {
                let result = Darwin.write(fd, bytes + offset, count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += result
            }
        }
    }

    /// gzip, one member or several, each checked against its CRC and length.
    static func gunzip(_ input: FileHandle, into sink: inout Sink) throws {
        var stream = z_stream()
        // 15 window bits, plus 16 for a gzip wrapper.
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DockerAPIError.internalError("could not start a gzip decoder")
        }
        defer { inflateEnd(&stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var atMemberEnd = false
        var sawInput = false
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            sawInput = true
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: Bytef.self).baseAddress
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(raw.count)
                while stream.avail_in > 0 {
                    if atMemberEnd {
                        // Another member follows.
                        guard inflateReset(&stream) == Z_OK else { throw DockerAPIError.badRequest("invalid gzip build context") }
                        atMemberEnd = false
                    }
                    stream.next_out = output
                    stream.avail_out = uInt(chunkSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    try sink.write(output, count: chunkSize - Int(stream.avail_out))
                    switch status {
                    case Z_STREAM_END:
                        atMemberEnd = true
                    case Z_OK:
                        continue
                    case Z_BUF_ERROR where stream.avail_out == 0:
                        // Output was full; there is more of it.
                        continue
                    default:
                        throw DockerAPIError.badRequest("invalid gzip build context")
                    }
                }
            }
        }
        // Whatever inflate still holds for the last input.
        while sawInput && !atMemberEnd {
            stream.next_out = output
            stream.avail_out = uInt(chunkSize)
            let status = inflate(&stream, Z_FINISH)
            try sink.write(output, count: chunkSize - Int(stream.avail_out))
            if status == Z_STREAM_END {
                atMemberEnd = true
            } else if (status != Z_OK && status != Z_BUF_ERROR) || stream.avail_out != 0 {
                // Output to come fills the buffer; anything else is a stream cut short.
                throw DockerAPIError.badRequest("invalid gzip build context: the stream ends early")
            }
        }
    }

    /// xz, through the system's LZMA decoder, which reads the xz container format.
    static func unxz(_ input: FileHandle, into sink: inout Sink) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw DockerAPIError.internalError("could not start an xz decoder")
        }
        defer { compression_stream_destroy(stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            let last = chunk.isEmpty
            let ended = try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress.map { UnsafePointer($0) } ?? UnsafePointer(output)
                stream.pointee.src_size = raw.count
                while true {
                    stream.pointee.dst_ptr = output
                    stream.pointee.dst_size = chunkSize
                    let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunkSize - stream.pointee.dst_size
                    try sink.write(output, count: produced)
                    switch status {
                    case COMPRESSION_STATUS_END:
                        return true
                    case COMPRESSION_STATUS_OK:
                        if stream.pointee.src_size > 0 || produced == chunkSize { continue }
                        if last { throw DockerAPIError.badRequest("invalid xz build context: the stream ends early") }
                        return false
                    default:
                        throw DockerAPIError.badRequest("invalid xz build context")
                    }
                }
            }
            if ended || last { return }
        }
    }
}
