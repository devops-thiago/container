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
            // As dockerd does, only a running container is followed, and only for as long as the
            // run it is in: a stopped one's log is printed and the command ends.
            let first = follow ? try await client.get(id: containerId) : nil
            let fhs = try await client.logs(id: containerId)
            let handle = boot ? fhs[1] : fhs[0]
            let id = containerId
            let lines = numLines
            // Placed on the log within the run it follows, so the next run's log is never taken
            // for this one's.
            let (run, reader) = try await ContainerSnapshot.startFollowing(first, look: { try await Self.look(id, client: client) }) {
                var reader = try LogFileReader(handle: handle)
                try reader.seek(tail: lines)
                return reader
            }
            guard let run else {
                try Self.printLog(from: reader)
                return
            }
            try await LogFileFollow.follow(handle, from: reader, runEnded: { try await Self.runEnded(run, client: client) }) { data in
                // Preserve raw stream bytes, including partial lines and UTF-8 scalars
                // split between reads. Converting each chunk to String loses both.
                FileHandle.standardOutput.write(data)
            }
        }

        /// The container now, or nil when it is gone.
        static func look(_ id: String, client: ContainerClient) async throws -> ContainerSnapshot? {
            do {
                return try await client.get(id: id)
            } catch let error as ContainerizationError where error.isCode(.notFound) {
                return nil
            }
        }

        /// Whether the container has left the run `run` was taken in: stopped, waiting to
        /// restart, started again, or deleted.
        static func runEnded(_ run: ContainerSnapshot, client: ContainerClient) async throws -> Bool {
            try await !(look(run.id, client: client)?.isInRun(of: run) ?? false)
        }

        /// What the log holds from where `start` is, as raw bytes: a retained segment can start
        /// mid-line or mid-scalar, and blank lines are the container's output too. Up to the end it
        /// had when the print began, so a container writing faster than this prints does not keep
        /// it going.
        private static func printLog(from start: LogFileReader) throws {
            var reader = start
            let end = try reader.size()
            while reader.offset < end {
                let data = try reader.next()
                if data.isEmpty { break }
                FileHandle.standardOutput.write(data)
            }
        }
    }
}
