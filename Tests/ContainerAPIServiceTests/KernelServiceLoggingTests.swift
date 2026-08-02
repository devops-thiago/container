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

import ContainerAPIService
import Containerization
import Foundation
import Logging
import Testing

struct KernelServiceLoggingTests {
    private struct Entry: Sendable {
        let message: String
        let metadata: [String: String]
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Entry] = []

        func append(message: String, metadata: Logger.Metadata) {
            lock.withLock {
                entries.append(
                    Entry(
                        message: message,
                        metadata: metadata.mapValues { String(describing: $0) }))
            }
        }

        var values: [Entry] {
            lock.withLock { entries }
        }
    }

    private struct CapturingLogHandler: LogHandler {
        var logLevel: Logger.Level = .trace
        var metadata: Logger.Metadata = [:]
        let capture: Capture

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata explicitMetadata: Logger.Metadata?,
            source: String,
            file: String,
            function: String,
            line: UInt
        ) {
            var combinedMetadata = metadata
            if let explicitMetadata {
                combinedMetadata.merge(explicitMetadata) { _, explicit in explicit }
            }
            capture.append(message: message.description, metadata: combinedMetadata)
        }
    }

    @Test("kernel source URLs are omitted from daemon debug metadata")
    func sourceURLIsNotLogged() async throws {
        let sentinel = "sensitive-kernel-source-\(UUID().uuidString)"
        let source = try #require(URL(string: "unsupported-scheme://user:password@example.invalid/\(sentinel).tar?token=secret#fragment"))
        let appRoot = FileManager.default.temporaryDirectory
            .appending(path: "container-kernel-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: appRoot) }

        let capture = Capture()
        var logger = Logger(
            label: "KernelServiceLoggingTests",
            factory: { _ in CapturingLogHandler(capture: capture) })
        logger.logLevel = .debug
        let service = try KernelService(log: logger, appRoot: appRoot)

        do {
            try await service.installKernelFrom(
                tar: source,
                kernelFilePath: "kernel",
                platform: .linuxArm,
                progressUpdate: nil,
                force: false)
            Issue.record("expected the unsupported source URL to fail")
        } catch {
            // The unsupported scheme keeps this unit test local while exercising all three
            // debug statements around the download branch.
        }

        let entries = capture.values
        #expect(entries.contains { $0.message == "KernelService: enter" })
        #expect(entries.contains { $0.message == "KernelService: start download" })
        #expect(entries.contains { $0.message == "KernelService: exit" })
        #expect(entries.allSatisfy { $0.metadata["tar"] == nil })
        #expect(!entries.description.contains(sentinel))
        #expect(!entries.description.contains(source.absoluteString))
    }
}
