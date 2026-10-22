//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerLog
import ContainerResource
import ContainerizationError
import Darwin
import Dispatch
import Foundation

extension Application {
    public struct ContainerLogs: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Fetch container logs"
        )

        @Flag(name: .long, help: "Display the boot log for the container instead of stdio")
        var boot: Bool = false

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(
            name: [.customShort("n"), .customLong("tail")],
            help: "Number of lines to show from the end of the logs. If not provided this will print all of the logs")
        var numLines: Int?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func run() async throws {
            let client = ContainerClient()
            // Taken before the log is read: a run that ends while it is printed is still seen
            // ending. As dockerd does, only a running container is followed, and only for as
            // long as the run it is in: a stopped one's log is printed and the command ends.
            let run = follow ? try await client.get(id: containerId) : nil
            let fhs = try await client.logs(id: containerId)
            let fileHandle = boot ? fhs[1] : fhs[0]

            try await Self.tail(
                fh: fileHandle,
                n: numLines,
                runEnded: run.flatMap { run in
                    guard run.hasLiveProcess else { return nil }
                    return { try await Self.runEnded(run, client: client) }
                }
            )
        }

        /// Whether the container has left the run `run` was taken in: stopped, waiting to
        /// restart, started again, or deleted.
        static func runEnded(_ run: ContainerSnapshot, client: ContainerClient) async throws -> Bool {
            do {
                return try await !client.get(id: run.id).isInRun(of: run)
            } catch let error as ContainerizationError where error.isCode(.notFound) {
                return true
            }
        }

        private static func tail(
            fh: FileHandle,
            n: Int?,
            runEnded: (@Sendable () async throws -> Bool)?
        ) async throws {
            if let n {
                var buffer = Data()
                let size = try fh.seekToEnd()
                var offset = size
                var lines: [String] = []

                while offset > 0, lines.count < n {
                    let readSize = min(1024, offset)
                    offset -= readSize
                    try fh.seek(toOffset: offset)

                    let data = fh.readData(ofLength: Int(readSize))
                    buffer.insert(contentsOf: data, at: 0)

                    if let chunk = String(data: buffer, encoding: .utf8) {
                        lines = chunk.components(separatedBy: .newlines)
                        lines = lines.filter { !$0.isEmpty }
                    }
                }

                lines = Array(lines.suffix(n))
                for line in lines {
                    print(line)
                }
            } else {
                // Preserve raw bytes: a retained segment can start mid-line or mid-scalar.
                // Empty logs must still enter follow mode and wait for the first output.
                let data = try fh.readToEnd() ?? Data()
                FileHandle.standardOutput.write(data)
            }

            fflush(stdout)
            if let runEnded {
                setbuf(stdout, nil)
                try await Self.followFile(fh: fh, runEnded: runEnded)
            }
        }

        private static func followFile(fh: FileHandle, runEnded: @escaping @Sendable () async throws -> Bool) async throws {
            try await LogFileFollow.follow(fh, runEnded: runEnded) { data in
                // Preserve raw stream bytes, including partial lines and UTF-8 scalars
                // split between reads. Converting each chunk to String loses both.
                FileHandle.standardOutput.write(data)
            }
        }
    }
}
