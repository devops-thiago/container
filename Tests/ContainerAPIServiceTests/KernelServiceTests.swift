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

import Containerization
import ContainerizationArchive
import ContainerizationError
import CryptoKit
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct KernelServiceTests {
    @Test func installKernelFromLocalTarVerifiesDigest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let digest = try KernelService.sha256Hex(of: tarFile)

            try await service.installKernelFrom(
                tar: URL(string: tarFile.path)!,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromLocalTarRejectsDigestMismatchWithoutInstalling() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let wrongDigest = String(repeating: "0", count: 64)

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(fileURLWithPath: tarFile.path),
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(wrongDigest)",
                    force: false)
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromLocalTarRejectsInvalidDigestValues() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let sha256 = try KernelService.sha256Hex(of: tarFile)
            let sha1 = try Self.sha1Hex(of: tarFile)
            let invalidDigests = [
                "sha256-not-a-digest",
                "sha1:\(sha1)",
                "sha256:not-a-digest",
                String(repeating: "0", count: 64),
                "sha256:\(String(sha256.dropLast(2)))",
                "sha256:\(sha1)",
            ]

            for digest in invalidDigests {
                await #expect(throws: ContainerizationError.self) {
                    try await service.installKernelFrom(
                        tar: URL(fileURLWithPath: tarFile.path),
                        kernelFilePath: kernelPath,
                        platform: .linuxArm,
                        progressUpdate: nil,
                        expectedDigest: digest,
                        force: false)
                }
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromRemoteTarRequiresDigest() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(string: "https://example.com/kernel.tar")!,
                    kernelFilePath: "boot/vmlinux",
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: nil,
                    force: false)
            }
        }
    }

    @Test func forcedSameNameReplacementKeepsTheOldKernelWhenStagingFails() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let source = tempDir.appendingPathComponent("vmlinux")
            let oldBytes = Data("old working kernel".utf8)
            try oldBytes.write(to: source)
            try await service.installKernel(kernelFile: source, platform: .linuxArm, force: false)
            let installed = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: installed.path) == oldBytes)

            // Same basename, new bytes, and a failure injected after the copy is staged —
            // the moment the old code had already deleted the working kernel.
            let newBytes = Data("replacement kernel that never lands".utf8)
            try newBytes.write(to: source)
            struct Injected: Error {}
            await service.setInstallHooks(.init(afterStaging: { throw Injected() }))
            await #expect(throws: Injected.self) {
                try await service.installKernel(kernelFile: source, platform: .linuxArm, force: true)
            }

            let after = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(after.path == installed.path, "the default still names the same kernel file")
            #expect(try Data(contentsOf: after.path) == oldBytes, "and its bytes are the old ones")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.path.deletingLastPathComponent().path)
                .filter { $0.contains(".staging-") }
            #expect(leftovers.isEmpty, "no staging object is left behind")
        }
    }

    @Test func forcedSameNameReplacementSwapsTheBytesAtomically() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let source = tempDir.appendingPathComponent("vmlinux")
            try Data("old".utf8).write(to: source)
            try await service.installKernel(kernelFile: source, platform: .linuxArm, force: false)
            let before = try await service.getDefaultKernel(platform: .linuxArm)

            let newBytes = Data("new kernel bytes".utf8)
            try newBytes.write(to: source)
            try await service.installKernel(kernelFile: source, platform: .linuxArm, force: true)

            let after = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(after.path == before.path, "same name, same default")
            #expect(try Data(contentsOf: after.path) == newBytes)
        }
    }

    @Test func unforcedInstallRefusesToReplaceAnExistingKernel() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let source = tempDir.appendingPathComponent("vmlinux")
            try Data("first".utf8).write(to: source)
            try await service.installKernel(kernelFile: source, platform: .linuxArm, force: false)
            try Data("second".utf8).write(to: source)
            await #expect(throws: ContainerizationError.self) {
                try await service.installKernel(kernelFile: source, platform: .linuxArm, force: false)
            }
            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == Data("first".utf8))
        }
    }

    private static func writeTar(at tarFile: URL, path: String, data: Data) throws -> URL {
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarFile)
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = numericCast(data.count)
        try archiver.writeEntry(entry: entry, data: data)
        try archiver.finishEncoding()
        return tarFile
    }

    private static func sha1Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withTempDir(body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
