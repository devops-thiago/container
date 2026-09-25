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
import ContainerResource
import ContainerizationExtras
import Foundation
import SwiftProtobuf

extension Application {
    public struct ContainerList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List running containers",
            aliases: ["ls"])

        @Flag(name: .shortAndLong, help: "Include containers that are not running")
        var all = false

        @Option(
            name: .long,
            help: "Only list containers matching a condition; repeat to require several (format: label=<key>, label=<key>=<value>, name=<regex> or status=<status>)",
            transform: { try Filter(parsing: $0) })
        var filter: [Filter] = []

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the container ID")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let client = ContainerClient()

            let filters = try Self.filters(for: filter, all: all).withoutMachines()
            let containers = try await client.list(filters: filters)
            let items = containers.map { ManagedContainer($0) }
            try Output.render(payload: items, display: items, format: format, quiet: quiet)
        }
    }
}

extension Application.ContainerList {
    /// One `--filter` condition, in the terms the engine filters by. A label value becomes
    /// the pattern that matches exactly it, so what the user typed is never read as a
    /// regular expression; a name is one, and is passed on as typed.
    enum Filter: Equatable {
        case label(key: String, pattern: String)
        case name(String)
        case status(RuntimeStatus)

        /// The engine reads a label a container lacks as an empty value, so asking for a
        /// label's presence is asking for any character at all.
        private static let anyValue = "[\\s\\S]"

        init(parsing argument: String) throws {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError("expected <key>=<value>, where the key is label, name or status")
            }
            let key = String(parts[0])
            let value = String(parts[1])
            switch key {
            case "label":
                self = try Self.label(parsing: value)
            case "name":
                guard !value.isEmpty else {
                    throw ValidationError("name needs a regular expression to search the container names for")
                }
                self = .name(value)
            case "status":
                guard let status = RuntimeStatus(rawValue: value) else {
                    let known = RuntimeStatus.allCases.map(\.rawValue).joined(separator: ", ")
                    throw ValidationError("unknown status '\(value)'; the statuses are \(known)")
                }
                self = .status(status)
            default:
                throw ValidationError("unknown filter '\(key)'; the filters are label, name and status")
            }
        }

        private static func label(parsing specification: String) throws -> Filter {
            let parts = specification.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty else {
                throw ValidationError("label needs a key, as in label=app or label=app=web")
            }
            guard parts.count == 2 else {
                return .label(key: key, pattern: anyValue)
            }
            let value = String(parts[1])
            // An empty value would also match the containers without the label, which
            // nobody who typed a value asked for.
            guard !value.isEmpty else {
                throw ValidationError("label \(key) needs a value after its '='; label=\(key) matches it with any value")
            }
            return .label(key: key, pattern: "^\(NSRegularExpression.escapedPattern(for: value))$")
        }
    }

    /// The engine's filters for `conditions`, all of which a listed container satisfies.
    /// A status condition takes the place of the default that hides stopped containers,
    /// so `status=stopped` lists them without `--all`.
    static func filters(for conditions: [Filter], all: Bool) throws -> ContainerListFilters {
        var labels: [String: String] = [:]
        var name: String?
        var status: RuntimeStatus?
        for condition in conditions {
            switch condition {
            case .label(let key, let pattern):
                // A container has one value per label, so a second condition on the same
                // key could only contradict the first.
                guard labels.updateValue(pattern, forKey: key) == nil else {
                    throw ValidationError("label \(key) is filtered more than once")
                }
            case .name(let pattern):
                guard name == nil else {
                    throw ValidationError("name is filtered more than once; one regular expression can list alternatives, as in name=^(web|db)$")
                }
                name = pattern
            case .status(let value):
                guard status == nil else {
                    throw ValidationError("status is filtered more than once")
                }
                status = value
            }
        }
        return ContainerListFilters(status: status ?? (all ? nil : .running), labels: labels, name: name)
    }
}
