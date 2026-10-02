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

import ContainerCompose
import Darwin
import Foundation
import TerminalProgress

/// Says what compose is doing, a line per step, on standard error: standard output is for
/// what a command was asked to print.
///
/// While a container is being made its image may be fetched, which is the one step with
/// progress worth a bar; the bar lives between that container's "Creating" and "Created".
final class ConsoleReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var bar: ProgressBar?
    private let isTerminal = isatty(FileHandle.standardError.fileDescriptor) == 1
    private let quiet: Bool

    init(quiet: Bool = false) {
        self.quiet = quiet
    }

    var hooks: ComposeHooks {
        ComposeHooks(
            event: { [self] in report($0) },
            progress: { [self] _ in
                { [self] updates in
                    let current = lock.withLock { bar }
                    current?.handler(updates)
                }
            },
            warning: { [self] in warn($0) })
    }

    func warn(_ message: String) {
        finishBar()
        write("warning: \(message)")
    }

    func report(_ event: ComposeEvent) {
        finishBar()
        guard !quiet else { return }
        let subject = event.subject.rawValue.prefix(1).uppercased() + event.subject.rawValue.dropFirst()
        var line = "\(subject) \(event.name)  \(Self.describe(event.status))"
        // Why something failed is the error the command ends with; said here too, it
        // would be said twice.
        if let detail = event.detail, event.status != .failed { line += " \(detail)" }
        write(line)

        // Making a container, or fetching an image, is where the engine reports progress.
        let fetches =
            (event.subject == .container && (event.status == .creating || event.status == .recreating))
            || (event.subject == .image && event.status == .pulling)
        guard fetches, isTerminal, let config = try? ProgressConfig(showTasks: true, showItems: true, ignoreSmallSize: true, totalTasks: 4) else {
            return
        }
        let started = ProgressBar(config: config)
        started.start()
        lock.withLock { bar = started }
    }

    func finishBar() {
        let current = lock.withLock { () -> ProgressBar? in
            defer { bar = nil }
            return bar
        }
        current?.finish()
    }

    private func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func describe(_ status: ComposeEvent.Status) -> String {
        switch status {
        case .creating: return "Creating"
        case .created: return "Created"
        case .exists: return "Exists"
        case .recreating: return "Recreating"
        case .pulling: return "Pulling"
        case .pulled: return "Pulled"
        case .building: return "Building"
        case .built: return "Built"
        case .starting: return "Starting"
        case .started: return "Started"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .healthy: return "Healthy"
        case .completed: return "Exited"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .removing: return "Removing"
        case .removed: return "Removed"
        case .failed: return "Failed"
        }
    }
}
