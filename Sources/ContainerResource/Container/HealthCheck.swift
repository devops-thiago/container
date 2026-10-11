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

import Foundation

/// How the engine checks that a container's workload works, in the shape of Docker's
/// `HEALTHCHECK` and its `--health-*` flags.
///
/// The fields are Docker's, with Docker's units: durations are whole nanoseconds, and zero
/// in any of them, or in `retries`, means "not given". At create a value not given by the
/// command line is taken from the image's check, and one given by neither is the default
/// when the check runs.
public struct HealthCheckConfiguration: Sendable, Codable, Equatable {
    /// The first word of a test that turns the check off.
    public static let disabledTest = "NONE"
    /// The first word of a test whose other words are the command, run as they are.
    public static let execTest = "CMD"
    /// The first word of a test whose second word is a command line for the shell.
    public static let shellTest = "CMD-SHELL"

    /// The shell a `CMD-SHELL` test runs in.
    public static let shell = ["/bin/sh", "-c"]

    public static let defaultInterval: Duration = .seconds(30)
    public static let defaultTimeout: Duration = .seconds(30)
    public static let defaultStartPeriod: Duration = .zero
    public static let defaultStartInterval: Duration = .seconds(5)
    public static let defaultRetries = 3
    /// The shortest duration a check accepts, when it gives one.
    public static let minimumDuration: Duration = .milliseconds(1)

    /// What to run: empty for the image's check, `["NONE"]` for none, `["CMD", command...]`
    /// or `["CMD-SHELL", command line]`.
    public var test: [String]
    /// Nanoseconds between the end of one check and the start of the next.
    public var interval: Int64
    /// Nanoseconds one check may take before it is killed and counted as a failure.
    public var timeout: Int64
    /// Nanoseconds after the start in which failures do not count.
    public var startPeriod: Int64
    /// Nanoseconds between checks during the start period.
    public var startInterval: Int64
    /// How many failures in a row make the container unhealthy.
    public var retries: Int

    public init(
        test: [String] = [],
        interval: Int64 = 0,
        timeout: Int64 = 0,
        startPeriod: Int64 = 0,
        startInterval: Int64 = 0,
        retries: Int = 0
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.startPeriod = startPeriod
        self.startInterval = startInterval
        self.retries = retries
    }

    private enum CodingKeys: String, CodingKey {
        case test
        case interval
        case timeout
        case startPeriod
        case startInterval
        case retries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decodeIfPresent([String].self, forKey: .test) ?? []
        interval = try container.decodeIfPresent(Int64.self, forKey: .interval) ?? 0
        timeout = try container.decodeIfPresent(Int64.self, forKey: .timeout) ?? 0
        startPeriod = try container.decodeIfPresent(Int64.self, forKey: .startPeriod) ?? 0
        startInterval = try container.decodeIfPresent(Int64.self, forKey: .startInterval) ?? 0
        retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? 0
    }

    /// A check that turns off the image's.
    public static var disabled: HealthCheckConfiguration {
        HealthCheckConfiguration(test: [disabledTest])
    }

    /// Whether the test turns the check off.
    public var disables: Bool { test.first == Self.disabledTest }

    /// The command the guest runs for one check, or nil when there is nothing to run: no
    /// test, `NONE`, or a test of a kind Docker does not know either.
    public var command: [String]? {
        switch test.first {
        case Self.execTest:
            let command = Array(test.dropFirst())
            return command.isEmpty ? nil : command
        case Self.shellTest:
            let line = Array(test.dropFirst())
            return line.isEmpty ? nil : Self.shell + line
        default:
            return nil
        }
    }

    public var effectiveInterval: Duration { Self.duration(interval, or: Self.defaultInterval) }
    public var effectiveTimeout: Duration { Self.duration(timeout, or: Self.defaultTimeout) }
    public var effectiveStartPeriod: Duration { Self.duration(startPeriod, or: Self.defaultStartPeriod) }
    public var effectiveStartInterval: Duration { Self.duration(startInterval, or: Self.defaultStartInterval) }
    public var effectiveRetries: Int { retries > 0 ? retries : Self.defaultRetries }

    private static func duration(_ nanoseconds: Int64, or fallback: Duration) -> Duration {
        nanoseconds > 0 ? .nanoseconds(nanoseconds) : fallback
    }

    /// The check a container gets at create, as Docker settles it: what the command line
    /// gives, field by field, over what the image gives. Nil when the result runs nothing:
    /// neither gives a test, or the one that counts is `NONE`.
    public static func resolve(user: HealthCheckConfiguration?, image: HealthCheckConfiguration?) -> HealthCheckConfiguration? {
        var result: HealthCheckConfiguration
        switch (user, image) {
        case (nil, nil):
            return nil
        case (let user?, nil):
            result = user
        case (nil, let image?):
            result = image
        case (var user?, let image?):
            if user.test.isEmpty { user.test = image.test }
            if user.interval == 0 { user.interval = image.interval }
            if user.timeout == 0 { user.timeout = image.timeout }
            if user.startPeriod == 0 { user.startPeriod = image.startPeriod }
            if user.startInterval == 0 { user.startInterval = image.startInterval }
            if user.retries == 0 { user.retries = image.retries }
            result = user
        }
        return result.command == nil ? nil : result
    }

    /// Refuse values Docker refuses: negative or sub-millisecond durations, and a negative
    /// count of retries.
    public func validate() throws {
        let durations: [(String, Int64)] = [
            ("interval", interval), ("timeout", timeout), ("start period", startPeriod), ("start interval", startInterval),
        ]
        for (name, value) in durations where value != 0 && Duration.nanoseconds(value) < Self.minimumDuration {
            throw HealthCheckError("the health check's \(name) cannot be less than 1ms")
        }
        guard retries >= 0 else {
            throw HealthCheckError("the health check's retries cannot be negative")
        }
    }

    /// Nanoseconds in a duration, for the fields above.
    public static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    /// A duration written as Docker writes one: `30s`, `1m30s`, `500ms`.
    public static func format(_ duration: Duration) -> String {
        var nanoseconds = Self.nanoseconds(duration)
        guard nanoseconds != 0 else { return "0s" }
        var text = nanoseconds < 0 ? "-" : ""
        nanoseconds = abs(nanoseconds)
        if nanoseconds < 1_000_000_000 {
            let unit: (size: Int64, name: String) =
                nanoseconds >= 1_000_000 ? (1_000_000, "ms") : nanoseconds >= 1_000 ? (1_000, "µs") : (1, "ns")
            return text + Self.decimal(nanoseconds, over: unit.size) + unit.name
        }
        let hours = nanoseconds / 3_600_000_000_000
        let minutes = (nanoseconds / 60_000_000_000) % 60
        let rest = nanoseconds % 60_000_000_000
        if hours > 0 { text += "\(hours)h" }
        if hours > 0 || minutes > 0 { text += "\(minutes)m" }
        return text + Self.decimal(rest, over: 1_000_000_000) + "s"
    }

    private static func decimal(_ value: Int64, over size: Int64) -> String {
        let whole = value / size
        let fraction = value % size
        guard fraction != 0 else { return "\(whole)" }
        var digits = String(fraction)
        digits = String(repeating: "0", count: String(size).count - 1 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits)"
    }

    /// A duration as Go's `time.ParseDuration` reads it, which is how Docker reads the
    /// `--health-*` durations: a sequence of numbers with units (`ns`, `us`, `µs`, `ms`,
    /// `s`, `m`, `h`), such as `1m30s` or `1.5s`, optionally signed; a bare `0` is zero.
    /// Nil for anything else, a number without a unit among it.
    public static func parseDuration(_ text: String) -> Duration? {
        var rest = Substring(text)
        var negative = false
        if let sign = rest.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            rest = rest.dropFirst()
        }
        if rest == "0" { return .zero }
        guard !rest.isEmpty else { return nil }
        // Two-letter units first, so that "ms" is not read as "m" followed by "s".
        let units: [(String, Double)] = [
            ("ns", 1), ("us", 1e3), ("µs", 1e3), ("μs", 1e3), ("ms", 1e6), ("s", 1e9), ("m", 6e10), ("h", 3.6e12),
        ]
        var total = 0.0
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard !digits.isEmpty, digits != ".", let value = Double(digits) else { return nil }
            rest = rest[digits.endIndex...]
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * unit.1
            rest = rest.dropFirst(unit.0.count)
        }
        guard total <= Double(Int64.max) else { return nil }
        let nanoseconds = Int64(total.rounded())
        return .nanoseconds(negative ? -nanoseconds : nanoseconds)
    }
}

/// A health check that cannot be used as given.
public struct HealthCheckError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Where a container's health stands, as Docker reports it.
public enum HealthStatus: String, Sendable, Codable, CaseIterable {
    /// No check has passed yet, and not enough have failed to say otherwise.
    case starting
    /// The last check passed.
    case healthy
    /// `retries` checks in a row failed, or the container stopped while it was checked.
    case unhealthy
}

/// One run of a container's health check.
public struct HealthCheckResult: Sendable, Codable, Equatable {
    public var start: Date
    public var end: Date
    /// 0 passed; any other code failed. -1 when the check could not be run, or was killed
    /// for taking longer than its timeout.
    public var exitCode: Int32
    /// What the check wrote, its output and its errors together, up to
    /// `ContainerHealth.maximumOutputBytes`; or why it could not be run.
    public var output: String

    public init(start: Date, end: Date, exitCode: Int32, output: String) {
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.output = output
    }
}

/// A container's health: Docker's `State.Health`.
public struct ContainerHealth: Sendable, Codable, Equatable {
    /// How many results are kept, the last ones.
    public static let maximumLogEntries = 5
    /// How much of a check's output is kept.
    public static let maximumOutputBytes = 4096

    public var status: HealthStatus
    /// Failed checks since the last one that passed, counting only the failures that count:
    /// not those in the start period before any check has passed.
    public var failingStreak: Int
    /// The last results, oldest first.
    public var log: [HealthCheckResult]

    public init(status: HealthStatus = .starting, failingStreak: Int = 0, log: [HealthCheckResult] = []) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case failingStreak
        case log
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(HealthStatus.self, forKey: .status) ?? .starting
        failingStreak = try container.decodeIfPresent(Int.self, forKey: .failingStreak) ?? 0
        log = try container.decodeIfPresent([HealthCheckResult].self, forKey: .log) ?? []
    }

    /// Take one result, by Docker's rules. A pass makes the container healthy and ends the
    /// streak. A failure counts towards it, unless no check has passed yet and the check
    /// started within the start period; once the streak reaches `retries` the container is
    /// unhealthy. A failure short of that leaves the status as it was.
    ///
    /// - Parameter sinceStart: how long after the container started this check started.
    /// - Returns: whether the status changed.
    @discardableResult
    public mutating func record(
        _ result: HealthCheckResult, sinceStart: Duration, startPeriod: Duration, retries: Int
    ) -> Bool {
        let before = status
        log.append(result)
        if log.count > Self.maximumLogEntries {
            log.removeFirst(log.count - Self.maximumLogEntries)
        }
        if result.exitCode == 0 {
            failingStreak = 0
            status = .healthy
        } else if !(status == .starting && sinceStart < startPeriod) {
            failingStreak += 1
            if failingStreak >= max(retries, 1) {
                status = .unhealthy
            }
        }
        return status != before
    }

    /// How long to wait before the next check, by Docker's schedule: the start interval
    /// while nothing has passed yet within the start period, no longer than what is left
    /// of the period; the interval otherwise.
    public static func delayBeforeNextCheck(
        status: HealthStatus, sinceStart: Duration, check: HealthCheckConfiguration
    ) -> Duration {
        let startPeriod = check.effectiveStartPeriod
        guard sinceStart < startPeriod, status == .starting else {
            return check.effectiveInterval
        }
        return min(check.effectiveStartInterval, startPeriod - sinceStart)
    }

    /// Output as it is kept: the first `maximumOutputBytes`, and `...` when there was more.
    public static func keptOutput(_ data: Data, truncated: Bool) -> String {
        let kept = data.prefix(maximumOutputBytes)
        // A cut through a multi-byte character is mended rather than dropped.
        let text = String(decoding: kept, as: UTF8.self)
        return truncated || data.count > maximumOutputBytes ? text + "..." : text
    }
}
