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

import ContainerizationError
import Darwin
import Dispatch
import Foundation
import Synchronization

private final class LaunchctlOutput: Sendable {
    private let storage = Mutex(Data())

    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    func snapshot() -> Data {
        storage.withLock { $0 }
    }
}

public struct ServiceManager {
    private static let terminationGrace: TimeInterval = 0.1

    private static func runLaunchctlCommand(args: [String], timeout: TimeInterval? = nil) throws -> Int32 {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = args

        let null = FileHandle.nullDevice
        launchctl.standardOutput = null
        launchctl.standardError = null

        return try runLaunchctlProcess(launchctl, args: args, timeout: timeout)
    }

    private static func runLaunchctlProcess(
        _ launchctl: Foundation.Process,
        args: [String],
        timeout: TimeInterval?,
        onStarted: () -> Void = {}
    ) throws -> Int32 {
        let exited = DispatchSemaphore(value: 0)
        launchctl.terminationHandler = { _ in exited.signal() }
        try launchctl.run()
        onStarted()

        if let timeout {
            let boundedTimeout = max(0, timeout)
            let terminationBudget = min(Self.terminationGrace, boundedTimeout)
            let executionBudget = boundedTimeout - terminationBudget
            if exited.wait(timeout: .now() + executionBudget) == .timedOut {
                launchctl.terminate()
                if exited.wait(timeout: .now() + terminationBudget) == .timedOut {
                    _ = Darwin.kill(launchctl.processIdentifier, SIGKILL)
                }
                throw ContainerizationError(
                    .internalError,
                    message: "command `launchctl \(args.joined(separator: " "))` timed out"
                )
            }
        } else {
            exited.wait()
        }

        return launchctl.terminationStatus
    }

    private static func launchctlDeadline(
        timeout: TimeInterval?
    ) -> ContinuousClock.Instant? {
        timeout.map {
            ContinuousClock().now.advanced(by: .seconds(max(0, $0)))
        }
    }

    private static func remainingLaunchctlTimeout(
        until deadline: ContinuousClock.Instant?
    ) -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func waitForCapture(
        _ group: DispatchGroup,
        args: [String],
        until deadline: ContinuousClock.Instant?
    ) throws {
        guard let deadline else {
            group.wait()
            return
        }
        let timeout = remainingLaunchctlTimeout(until: deadline) ?? 0
        guard group.wait(timeout: .now() + timeout) == .success else {
            throw ContainerizationError(
                .internalError,
                message: "command `launchctl \(args.joined(separator: " "))` timed out draining output"
            )
        }
    }

    private static func startCapture(
        from handle: FileHandle,
        into storage: LaunchctlOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            storage.append(handle.readDataToEndOfFile())
        }
    }

    /// Register a service by providing the path to a plist.
    public static func register(plistPath: String) throws {
        let domain = try Self.getDomainString()
        _ = try runLaunchctlCommand(args: ["bootstrap", domain, plistPath])
    }

    /// Deregister a service by a launchd label.
    public static func deregister(fullServiceLabel label: String, timeout: TimeInterval? = nil) throws {
        let status = try runLaunchctlCommand(args: ["bootout", label], timeout: timeout)
        guard status == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "command `launchctl bootout \(label)` failed with status \(status)"
            )
        }
    }

    /// Deregister a service and pass return status
    public static func deregister(fullServiceLabel label: String, status: inout Int32) throws {
        status = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Restart a service by a launchd label.
    public static func kickstart(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["kickstart", "-k", label])
    }

    /// Send a signal to a service by a launchd label.
    public static func kill(fullServiceLabel label: String, signal: Int32 = 15) throws {
        _ = try runLaunchctlCommand(args: ["kill", "\(signal)", label])
    }

    /// Retrieve labels for all loaded launch units.
    public static func enumerate(timeout: TimeInterval? = nil) throws -> [String] {
        let deadline = launchctlDeadline(timeout: timeout)
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["list"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = stderrPipe
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        let outputData = LaunchctlOutput()
        let stderrData = LaunchctlOutput()
        let captureGroup = DispatchGroup()
        let status = try runLaunchctlProcess(
            launchctl,
            args: ["list"],
            timeout: remainingLaunchctlTimeout(until: deadline)
        ) {
            startCapture(from: stdoutPipe.fileHandleForReading, into: outputData, group: captureGroup)
            startCapture(from: stderrPipe.fileHandleForReading, into: stderrData, group: captureGroup)
        }
        try waitForCapture(captureGroup, args: ["list"], until: deadline)
        let output = outputData.snapshot()
        let stderr = stderrData.snapshot()
        guard status == 0 else {
            throw ContainerizationError(
                .internalError, message: "command `launchctl list` failed with status \(status), message: \(String(data: stderr, encoding: .utf8) ?? "no error message")")
        }

        guard let outputText = String(data: output, encoding: .utf8) else {
            throw ContainerizationError(
                .internalError, message: "could not decode output of command `launchctl list`, message: \(String(data: stderr, encoding: .utf8) ?? "no error message")")
        }

        // The third field of each line of launchctl list output is the label
        return outputText.split { $0.isNewline }
            .map { String($0).split { $0.isWhitespace } }
            .filter { $0.count >= 3 }
            .map { String($0[2]) }
    }

    /// Check if a service has been registered or not.
    public static func isRegistered(
        fullServiceLabel label: String,
        timeout: TimeInterval? = nil
    ) throws -> Bool {
        let exitStatus = try runLaunchctlCommand(args: ["list", label], timeout: timeout)
        return exitStatus == 0
    }

    private static func getLaunchdSessionType(timeout: TimeInterval? = nil) throws -> String {
        let deadline = launchctlDeadline(timeout: timeout)
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["managername"]

        let null = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = null
        defer {
            try? stdoutPipe.fileHandleForReading.close()
        }

        let outputData = LaunchctlOutput()
        let captureGroup = DispatchGroup()
        let status = try runLaunchctlProcess(
            launchctl,
            args: ["managername"],
            timeout: remainingLaunchctlTimeout(until: deadline)
        ) {
            startCapture(from: stdoutPipe.fileHandleForReading, into: outputData, group: captureGroup)
        }
        try waitForCapture(captureGroup, args: ["managername"], until: deadline)
        let output = outputData.snapshot()
        guard status == 0 else {
            throw ContainerizationError(.internalError, message: "command `launchctl managername` failed with status \(status)")
        }
        guard let outputText = String(data: output, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "could not decode output of command `launchctl managername`")
        }
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func getDomainString(timeout: TimeInterval? = nil) throws -> String {
        let currentSessionType = try getLaunchdSessionType(timeout: timeout)
        switch currentSessionType {
        case LaunchPlist.Domain.System.rawValue:
            return LaunchPlist.Domain.System.rawValue.lowercased()
        case LaunchPlist.Domain.Background.rawValue:
            return "user/\(getuid())"
        case LaunchPlist.Domain.Aqua.rawValue:
            return "gui/\(getuid())"
        default:
            throw ContainerizationError(.internalError, message: "unsupported session type \(currentSessionType)")
        }
    }
}
