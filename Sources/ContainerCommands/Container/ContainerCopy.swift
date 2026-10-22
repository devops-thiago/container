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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import SystemPackage

extension Application {
    public struct ContainerCopy: AsyncLoggableCommand {
        enum PathRef: Equatable {
            case local(String)
            case container(id: String, path: String)
            /// `-`: a tar archive on stdin as the source, on stdout as the destination, as
            /// `docker cp` has it. A file named `-` is `./-`.
            case stream
        }

        static func parsePathRef(_ ref: String) throws -> PathRef {
            if ref == "-" { return .stream }
            let parts = ref.components(separatedBy: ":")
            switch parts.count {
            case 1:
                return .local(ref)
            case 2 where !parts[0].isEmpty && parts[1].starts(with: "/"):
                return .container(id: parts[0], path: parts[1])
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid path given: \(ref)")
            }
        }

        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "copy",
            abstract: "Copy files/folders between a container and the local filesystem",
            discussion: """
                Use '-' as the source to read a tar archive from stdin
                and extract it to a directory destination in a container.
                Use '-' as the destination to stream a tar archive of a
                container source to stdout.
                """,
            aliases: ["cp"])

        @OptionGroup()
        public var logOptions: Flags.Logging

        @Flag(name: [.customShort("L"), .customLong("follow-link")], help: "Always follow symlinks in SRC_PATH")
        var followLink = false

        /// `docker cp -a`: what is copied into a container belongs to the container's user,
        /// when it has one, instead of keeping its source's owner.
        @Flag(name: [.customShort("a"), .customLong("archive")], help: "Archive mode (copy all uid/gid information)")
        var archive = false

        @Argument(help: "Source path (container:path, local path, or - for a tar archive on stdin)")
        var source: String

        @Argument(help: "Destination path (container:path, local path, or - for a tar archive on stdout)")
        var destination: String

        public func run() async throws {
            let client = ContainerClient()
            let srcRef = try Self.parsePathRef(source)
            let dstRef = try Self.parsePathRef(destination)

            switch (srcRef, dstRef) {
            case (.container(let id, let path), .stream):
                try await ContainerCopyStream.copyOut(id: id, path: path, followLink: followLink, to: .standardOutput)
            case (.stream, .container(let id, let path)):
                try await ContainerCopyStream.copyIn(id: id, path: path, from: .standardInput, copyUIDGID: archive)
            case (.stream, _), (_, .stream):
                // The Docker CLI's words when neither side names a container.
                throw ContainerizationError(.invalidArgument, message: "must specify at least one container source")
            case (.container(let id, let path), .local(let localPath)):
                let srcPath = FilePath(path)
                let destPath = FilePath(HostPath.absolute(localPath))
                try await ClientHostDirectory.borrow([HostPath.folderForCopy(for: destPath.string)], verb: "write")
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: destPath.string, isDirectory: &isDirectory)

                var finalDestPath = destPath
                if exists && isDirectory.boolValue {
                    guard let lastComponent = srcPath.lastComponent else {
                        throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(path)")
                    }
                    finalDestPath = destPath.appending(lastComponent)
                    try await client.copyOut(id: id, source: path, destination: finalDestPath.string)
                } else if localPath.hasSuffix("/") {
                    try await client.copyOut(id: id, source: path, destination: destPath.string)
                    var resultIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: destPath.string, isDirectory: &resultIsDir),
                        !resultIsDir.boolValue
                    {
                        try? FileManager.default.removeItem(atPath: destPath.string)
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "destination is not a directory: \(localPath)")
                    }
                } else {
                    try await client.copyOut(id: id, source: path, destination: destPath.string)
                }
                print(finalDestPath.string)
            case (.local(let localPath), .container(let id, let path)):
                let srcPath = FilePath(HostPath.absolute(localPath))
                try await ClientHostDirectory.borrow([HostPath.folderForCopy(for: srcPath.string)], verb: "read")
                var isDirectory: ObjCBool = false

                guard let lastComponent = srcPath.lastComponent else {
                    throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(localPath)")
                }

                guard FileManager.default.fileExists(atPath: srcPath.string, isDirectory: &isDirectory) else {
                    throw ContainerizationError(.notFound, message: "source path does not exist: \(localPath)")
                }
                if localPath.hasSuffix("/") && !isDirectory.boolValue {
                    throw ContainerizationError(.invalidArgument, message: "source path is not a directory: \(localPath)")
                }

                // The file's own mode, as the Docker CLI puts it in the archive it sends: the
                // copy replaces what is at the destination, mode and all.
                var info = stat()
                let mode = stat(srcPath.string, &info) == 0 ? UInt32(info.st_mode) & 0o7777 : 0o644
                try await client.copyIn(id: id, source: srcPath.string, destination: path, mode: mode, createParents: true, copyUIDGID: archive)
                let printedDest = path.hasSuffix("/") ? "\(id):\(path)\(lastComponent.string)" : "\(id):\(path)"
                print(printedDest)
            case (.container, .container):
                throw ContainerizationError(.invalidArgument, message: "copying between containers is not supported")
            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "one of source or destination must be a container reference (container_id:path)")
            }
        }
    }
}
