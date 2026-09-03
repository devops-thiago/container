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
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import CryptoKit
import Darwin
import Foundation
import Logging
import TerminalProgress

public actor KernelService {
    private static let defaultKernelNamePrefix: String = "default.kernel-"
    private static let transactionDirectoryPrefix = ".kernel-transaction-"

    private let log: Logger
    private let kernelDirectory: URL

    private struct ExpectedDigest {
        let algorithm: String
        let hex: String
    }

    private struct KernelTransaction: Codable {
        let destinationName: String
        let defaultName: String
        let destinationExisted: Bool
        let expectedSHA256: String
    }

    private struct RollbackUncertain: Error {
        let cause: any Error
    }

    private struct TransactionInterrupted: Error {}

    public init(log: Logger, appRoot: URL) throws {
        self.log = log
        let fm = FileManager.default
        if !Self.pathExists(appRoot) {
            try fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
            try Self.syncDirectory(appRoot.deletingLastPathComponent())
        }
        self.kernelDirectory = appRoot.appending(path: "kernels")
        if !Self.pathExists(self.kernelDirectory) {
            try fm.createDirectory(at: self.kernelDirectory, withIntermediateDirectories: false)
            try Self.syncDirectory(appRoot)
        }
        if try Self.recoverTransactions(in: self.kernelDirectory, log: log) {
            try Self.syncDirectory(self.kernelDirectory)
        }
    }

    /// Copies a kernel binary from a local path on disk into the managed kernels directory
    /// as the default kernel for the provided platform.
    @discardableResult
    public func installKernel(kernelFile url: URL, platform: SystemPlatform = .linuxArm, force: Bool) throws -> KernelInstallation {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "kernelFile": "\(url)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "kernelFile": "\(url)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let kFile = url.resolvingSymlinksInPath()
        let name = kFile.lastPathComponent
        guard !name.hasPrefix(Self.transactionDirectoryPrefix) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel name \(name) uses the reserved transaction namespace")
        }
        let destPath = self.kernelDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        let destinationExists = Self.pathExists(destPath)

        if !force, destinationExists {
            throw ContainerizationError(.exists, message: "kernel \(name) is already installed")
        }

        let sourceDigest = try Self.sha256Hex(of: kFile)
        let defaultAlreadySelectsDestination = self.defaultKernelSelects(name: name, platform: platform)
        let transactionDirectory = self.kernelDirectory.appendingPathComponent(
            "\(Self.transactionDirectoryPrefix)\(UUID().uuidString)")
        let staged = transactionDirectory.appendingPathComponent("content")
        var cleanupTransaction = true
        try fm.createDirectory(at: transactionDirectory, withIntermediateDirectories: false)
        try Self.syncDirectory(self.kernelDirectory)
        defer {
            if cleanupTransaction, Self.pathExists(transactionDirectory) {
                do {
                    try fm.removeItem(at: transactionDirectory)
                    try Self.syncDirectory(self.kernelDirectory)
                } catch {
                    self.log.error("could not durably clean kernel transaction \(transactionDirectory.lastPathComponent): \(error)")
                }
            }
        }

        try fm.copyItem(at: kFile, to: staged)
        try Task.checkCancellation()
        try installHooks.afterStaging?(staged)
        try Self.verifyCopy(expectedSHA256: sourceDigest, at: staged)
        try Self.syncFile(staged)
        let transaction = KernelTransaction(
            destinationName: name,
            defaultName: "\(Self.defaultKernelNamePrefix)\(platform.architecture)",
            destinationExisted: destinationExists,
            expectedSHA256: sourceDigest)
        try Self.record(transaction, in: transactionDirectory)
        try installHooks.beforeContentCommit?()

        // When a destination already exists, swap names atomically instead of discarding the
        // old inode. It remains at `staged` until the default-link publication and directory
        // sync both succeed, so any later failure can swap it back.
        if destinationExists {
            try Self.swap(staged, destPath, operation: "replace the kernel")
        } else {
            try Self.rename(staged, destPath, operation: "move the staged kernel into place")
        }

        do {
            try syncKernelDirectory()
            if installHooks.interruptAfterContentCommit {
                throw TransactionInterrupted()
            }
            // Replacing bytes under the pathname an existing default symlink already selects
            // needs no link mutation. Avoiding it removes an otherwise separate failure point.
            if !defaultAlreadySelectsDestination {
                try self.setDefaultKernel(
                    name: name,
                    platform: platform,
                    transactionDirectory: transactionDirectory)
            }
        } catch is TransactionInterrupted {
            // Unit-level crash boundary: preserve the durable transaction exactly as a killed
            // process would, then let a fresh service instance exercise startup recovery.
            cleanupTransaction = false
            throw ContainerizationError(.internalError, message: "kernel transaction interrupted after content publication")
        } catch let uncertain as RollbackUncertain {
            // Keep both the old transaction content and the new destination. Recovery can
            // inspect the atomically selected default on the next service start; deleting
            // either side while link durability is unknown could leave a dangling default.
            cleanupTransaction = false
            log.critical("kernel transaction rollback is uncertain; preserving recovery state: \(uncertain.cause)")
            throw uncertain.cause
        } catch {
            do {
                if destinationExists {
                    try Self.swap(staged, destPath, operation: "roll back the kernel replacement")
                } else if Self.pathExists(destPath) {
                    try Self.rename(destPath, staged, operation: "roll back the kernel installation")
                }
                try Self.syncDirectory(self.kernelDirectory)
            } catch {
                cleanupTransaction = false
                self.log.critical("kernel replacement rollback failed; preserving recovery state: \(error)")
            }
            throw error
        }

        // The transaction directory holds the replaced content/link after a successful swap.
        // Deferred cleanup removes it only after both published names are durable.
        return KernelInstallation(name: name, sha256: sourceDigest)
    }

    /// Deterministic failure seams around each unit-testable transaction boundary.
    struct InstallHooks: Sendable {
        var afterStaging: (@Sendable (URL) throws -> Void)?
        var beforeContentCommit: (@Sendable () throws -> Void)?
        var beforeDefaultCommit: (@Sendable () throws -> Void)?
        var didSyncDirectory: (@Sendable () -> Void)?
        var interruptAfterContentCommit = false
    }
    private var installHooks = InstallHooks()

    func setInstallHooks(_ hooks: InstallHooks) {
        installHooks = hooks
    }

    private func syncKernelDirectory() throws {
        try Self.syncDirectory(kernelDirectory)
        installHooks.didSyncDirectory?()
    }

    private static func verifyCopy(expectedSHA256: String, at staged: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? UInt64
        let actual = try sha256Hex(of: staged)
        guard let size, size > 0, actual == expectedSHA256 else {
            throw ContainerizationError(
                .internalError,
                message: "staged kernel content does not match its source")
        }
    }

    private static func syncFile(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else {
            throw ContainerizationError(.internalError, message: "could not open the staged kernel to sync it")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ContainerizationError(.internalError, message: "could not sync the staged kernel")
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw ContainerizationError(.internalError, message: "could not open the kernel directory to sync it")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw ContainerizationError(.internalError, message: "could not sync the kernel directory")
        }
    }

    private static func record(_ transaction: KernelTransaction, in directory: URL) throws {
        let record = directory.appendingPathComponent("transaction.json")
        try JSONEncoder().encode(transaction).write(to: record, options: .atomic)
        try syncFile(record)
        try syncDirectory(directory)
        try syncDirectory(directory.deletingLastPathComponent())
    }

    /// Recover a process/host crash at any publication boundary. A transaction with the
    /// expected bytes and a default selecting them committed; expected bytes with the old
    /// default roll back. A directory without a durable record never reached publication.
    private static func recoverTransactions(in directory: URL, log: Logger) throws -> Bool {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey])
        var recovered = false
        for entry in entries where isTransactionDirectory(entry) {
            let recordURL = entry.appendingPathComponent("transaction.json")
            if fm.fileExists(atPath: recordURL.path) {
                let transaction = try JSONDecoder().decode(
                    KernelTransaction.self,
                    from: Data(contentsOf: recordURL))
                let destination = directory.appendingPathComponent(transaction.destinationName)
                let staged = entry.appendingPathComponent("content")
                let finalHasExpectedBytes: Bool
                if Self.pathExists(destination) {
                    finalHasExpectedBytes = try sha256Hex(of: destination) == transaction.expectedSHA256
                } else {
                    finalHasExpectedBytes = false
                }
                let defaultPath = directory.appendingPathComponent(transaction.defaultName)
                let committed =
                    finalHasExpectedBytes
                    && symbolicLink(defaultPath, selects: destination, relativeTo: directory)

                if finalHasExpectedBytes, !committed {
                    if transaction.destinationExisted, Self.pathExists(staged) {
                        try swap(staged, destination, operation: "recover the prior kernel")
                    } else if Self.pathExists(destination) {
                        try fm.removeItem(at: destination)
                    }
                    try syncDirectory(directory)
                    log.warning("rolled back interrupted kernel transaction \(entry.lastPathComponent)")
                } else if committed {
                    log.notice("completed cleanup for committed kernel transaction \(entry.lastPathComponent)")
                }
            }
            try fm.removeItem(at: entry)
            recovered = true
        }
        return recovered
    }

    private static func isTransactionDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(transactionDirectoryPrefix) else { return false }
        let suffix = String(name.dropFirst(transactionDirectoryPrefix.count))
        guard UUID(uuidString: suffix) != nil else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func symbolicLink(_ link: URL, selects destination: URL, relativeTo directory: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        return URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
            == destination.standardizedFileURL
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func rename(_ source: URL, _ destination: URL, operation: String) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "could not \(operation): \(String(cString: strerror(errno)))")
        }
    }

    private static func swap(_ first: URL, _ second: URL, operation: String) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "could not \(operation): \(String(cString: strerror(errno)))")
        }
    }

    private func defaultKernelSelects(name: String, platform: SystemPlatform) -> Bool {
        let defaultName = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultPath = kernelDirectory.appendingPathComponent(defaultName)
        return Self.symbolicLink(
            defaultPath,
            selects: kernelDirectory.appendingPathComponent(name),
            relativeTo: kernelDirectory)
    }

    /// Copies a kernel binary from inside of tar file into the managed kernels directory
    /// as the default kernel for the provided platform.
    /// The parameter `tar` maybe a location to a local file on disk, or a remote URL.
    @discardableResult
    public func installKernelFrom(
        tar: URL,
        kernelFilePath: String,
        platform: SystemPlatform,
        progressUpdate: ProgressUpdateHandler?,
        expectedDigest: String? = nil,
        force: Bool
    ) async throws -> KernelInstallation {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "kernelFilePath": "\(kernelFilePath)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "kernelFilePath": "\(kernelFilePath)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        var tarFile = tar
        let localTarPath = tar.scheme == nil || tar.isFileURL ? tar.path : nil
        let isLocalTar = localTarPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if isLocalTar, let localTarPath {
            tarFile = URL(fileURLWithPath: localTarPath)
        }
        guard isLocalTar || expectedDigest != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel archive digest is required for remote URL '\(tar)'"
            )
        }
        let expectedDigest = try expectedDigest.map(Self.parseExpectedDigest)

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        await progressUpdate?([
            .setDescription(isLocalTar ? "Reading kernel archive" : "Downloading kernel")
        ])
        if !isLocalTar {
            let taskManager = ProgressTaskCoordinator()
            let downloadTask = await taskManager.startTask()
            // No URL in the metadata: a kernel source can carry a token or an internal
            // hostname, and this log is world-readable.
            self.log.debug("KernelService: start download")
            tarFile = tempDir.appendingPathComponent(tar.lastPathComponent)
            var downloadProgressUpdate: ProgressUpdateHandler?
            if let progressUpdate {
                downloadProgressUpdate = ProgressTaskCoordinator.handler(for: downloadTask, from: progressUpdate)
            }
            try await ContainerAPIClient.FileDownloader.downloadFile(
                url: tar,
                to: tarFile,
                progressUpdate: downloadProgressUpdate)
            await taskManager.finish()
        }
        await progressUpdate?([
            .addTasks(1)
        ])

        if let expectedDigest {
            await progressUpdate?([
                .setDescription("Verifying kernel archive")
            ])
            try Self.verifyDigest(of: tarFile, expected: expectedDigest)
            await progressUpdate?([
                .addTasks(1)
            ])
        }

        await progressUpdate?([
            .setDescription("Unpacking kernel")
        ])
        let kernelFile = try self.extractFile(tarFile: tarFile, at: kernelFilePath, to: tempDir)
        let installation = try self.installKernel(kernelFile: kernelFile, platform: platform, force: force)
        await progressUpdate?([
            .addTasks(1)
        ])

        if !isLocalTar {
            try FileManager.default.removeItem(at: tarFile)
        }
        return installation
    }

    private static func verifyDigest(of file: URL, expected: ExpectedDigest) throws {
        let actualDigest = try sha256Hex(of: file)
        try verifyDigest(actualSHA256Hex: actualDigest, expected: expected)
    }

    private static func verifyDigest(actualSHA256Hex actualDigest: String, expected: ExpectedDigest) throws {
        guard actualDigest == expected.hex else {
            throw ContainerizationError(
                .invalidState,
                message: "kernel archive digest mismatch: expected sha256:\(expected.hex), got sha256:\(actualDigest)"
            )
        }
    }

    private static func parseExpectedDigest(_ expected: String) throws -> ExpectedDigest {
        let parts = expected.lowercased().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "invalid digest value '\(expected)': expected '<algorithm>:<hex>'")
        }
        let digest = ExpectedDigest(algorithm: String(parts[0]), hex: String(parts[1]))
        guard digest.algorithm == "sha256" else {
            throw ContainerizationError(.unsupported, message: "unsupported digest algorithm '\(digest.algorithm)'")
        }
        guard digest.hex.count == 64, digest.hex.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw ContainerizationError(.invalidArgument, message: "invalid sha256 digest value '\(expected)'")
        }
        return digest
    }

    static func sha256Hex(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: Int(1.mib())), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func setDefaultKernel(
        name: String,
        platform: SystemPlatform,
        transactionDirectory: URL
    ) throws {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let kernelPath = self.kernelDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw ContainerizationError(.notFound, message: "kernel not found at \(kernelPath)")
        }
        let defaultName = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(defaultName)
        let staged = transactionDirectory.appendingPathComponent("default")
        let hadDefault = Self.pathExists(defaultKernelPath)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: kernelPath)
        try Self.syncDirectory(transactionDirectory)
        try installHooks.beforeDefaultCommit?()

        if hadDefault {
            try Self.swap(staged, defaultKernelPath, operation: "switch the default kernel")
        } else {
            try Self.rename(staged, defaultKernelPath, operation: "publish the default kernel")
        }
        do {
            try syncKernelDirectory()
        } catch {
            do {
                if hadDefault {
                    try Self.swap(staged, defaultKernelPath, operation: "roll back the default kernel")
                } else if Self.pathExists(defaultKernelPath) {
                    try FileManager.default.removeItem(at: defaultKernelPath)
                }
                try Self.syncDirectory(kernelDirectory)
            } catch {
                throw RollbackUncertain(cause: error)
            }
            throw error
        }
    }

    public func getDefaultKernel(platform: SystemPlatform = .linuxArm) async throws -> Kernel {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let name = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: defaultKernelPath.path) else {
            throw ContainerizationError(.notFound, message: "default kernel not found at \(defaultKernelPath)")
        }
        return Kernel(path: defaultKernelPath, platform: platform)
    }

    private func extractFile(tarFile: URL, at: String, to directory: URL) throws -> URL {
        var target = at
        var archiveReader = try ArchiveReader(file: tarFile)
        var (entry, data) = try archiveReader.extractFile(path: target)

        // if the target file is a symlink, get the data for the actual file
        if entry.fileType == .symbolicLink, let symlinkRelative = entry.symlinkTarget {
            // the previous extractFile changes the underlying file pointer, so we need to reopen the file
            // to ensure we traverse all the files in the archive
            archiveReader = try ArchiveReader(file: tarFile)
            let symlinkTarget = URL(filePath: target).deletingLastPathComponent().appending(path: symlinkRelative)

            // standardize so that we remove any and all ../ and ./ in the path since symlink targets
            // are relative paths to the target file from the symlink's parent dir itself
            target = symlinkTarget.standardized.relativePath
            let (_, targetData) = try archiveReader.extractFile(path: target)
            data = targetData
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let fileName = URL(filePath: target).lastPathComponent
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
