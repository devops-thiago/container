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

import ContainerAPIClient
import ContainerizationArchive
import Foundation
import Synchronization
import Testing

@testable import ContainerBuild

@Suite struct BuildContextRaceTests {
    enum Swap: CaseIterable, Sendable {
        case ancestor
        case finalComponent
    }

    enum Transfer: CaseIterable, Sendable {
        case directRead
        case archive
        case fullWalk
    }

    @Test(arguments: Swap.allCases, Transfer.allCases)
    func pathSwapCannotTransferOutsideBytes(swap: Swap, transfer: Transfer) async throws {
        let fm = FileManager.default
        // Use the physical spelling so the pre-fix inventory also reaches the hook.
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let context = base.appendingPathComponent("context")
        let subdir = context.appendingPathComponent("subdir")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let payload = subdir.appendingPathComponent("payload.txt")
        let secret = outside.appendingPathComponent("payload.txt")
        try Data(String(repeating: "P", count: 20).utf8).write(to: payload)
        try Data("OUTSIDE-SENTINEL-157".utf8).write(to: secret)
        let mutations = Mutex(0)
        let mutate: @Sendable () throws -> Void = {
            mutations.withLock { $0 += 1 }
            let target = swap == .ancestor ? subdir : payload
            try FileManager.default.moveItem(at: target, to: base.appendingPathComponent("saved"))
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: swap == .ancestor ? outside : secret)
        }
        let tar = transfer != .directRead
        let noMutation: @Sendable () throws -> Void = {}
        let sync = try BuildFSSync(context, beforeRead: tar ? noMutation : mutate, beforeArchiveRead: tar ? mutate : noMutation)
        var packet = BuildTransfer()
        packet.id = "race"
        packet.source = tar ? "." : "subdir/payload.txt"
        packet.metadata = ["mode": "tar", "followpaths": "*", "length": "1024"]
        let (stream, continuation) = AsyncStream<ClientStream>.makeStream()
        var transmitted = Data()
        // A clear error on a changed source is also an acceptable secure result.
        do {
            if transfer == .fullWalk {
                try await sync.walk(continuation, packet, "build-race")
            } else if transfer == .archive {
                let destination = base.appendingPathComponent("context.tar")
                _ = try Archiver.compress(
                    source: context, destination: destination,
                    writerConfiguration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .none),
                    beforeReading: mutate
                ) { url in
                    guard url.lastPathComponent == "payload.txt" else { return nil }
                    return Archiver.ArchiveEntryInfo(pathOnHost: url, pathInArchive: URL(fileURLWithPath: "payload.txt"))
                }
                transmitted = try Data(contentsOf: destination)
            } else {
                try await sync.read(continuation, packet, "build-race")
            }
        } catch { /* A changed source may be rejected instead of transferred. */  }
        continuation.finish()
        for await response in stream { transmitted.append(response.buildTransfer.data) }
        #expect(mutations.withLock { $0 } == 1, "the test must reach the intended read boundary")
        #expect(transmitted.range(of: Data("OUTSIDE-SENTINEL-157".utf8)) == nil, "build-context transfer leaked outside bytes after \(swap)")
    }

}
