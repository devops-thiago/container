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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import DockerAPIEngine
import DockerAPIService
import Foundation

extension Application {
    /// `docker events`: the engine's container events as they happen, until stopped, with the
    /// Docker API's filters and messages. A container is named by its ID here.
    public struct ContainerEvents: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "Print container events as they happen")

        @Option(name: [.customShort("f"), .long], help: .init("Filter events (format: key=value, such as event=start or label=k=v)", valueName: "filter"))
        var filter: [String] = []

        @Option(name: .long, help: "Print each event as json, or through a Go template, such as {{json .}}")
        var format: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        public func validate() throws {
            _ = try eventFilter()
            _ = try template()
        }

        /// The filters, as `GET /events` takes them.
        func eventFilter() throws -> DockerEventFilter {
            var filters: [String: [String]] = [:]
            for item in filter {
                guard let equals = item.firstIndex(of: "="), equals != item.startIndex else {
                    throw ValidationError("bad format of filter (expected name=value)")
                }
                filters[String(item[..<equals]), default: []].append(String(item[item.index(after: equals)...]))
            }
            do {
                return try DockerEventFilter(filters)
            } catch {
                throw ValidationError(error.message)
            }
        }

        /// The template each event goes through; nil for Docker's line of text.
        func template() throws -> DockerTemplate? {
            guard let format else { return nil }
            let source = format == "json" ? "{{json .}}" : format
            guard DockerTemplate.isTemplate(source) else {
                throw ValidationError("--format takes json or a template, such as {{json .}}")
            }
            do {
                return try DockerTemplate(source)
            } catch {
                throw ValidationError(error.description)
            }
        }

        public func run() async throws {
            // Changes from here on are printed, the ones made while this attaches to the engine
            // included: a tool runs `events` and at once the command whose start it waits for.
            let began = Date()
            let filter = try eventFilter()
            let template = try template()
            let bus = DockerEventBus(
                log: log,
                source: {
                    try await ContainerClient().list(filters: ContainerListFilters.all.withoutInfrastructure()).map(DockerInspection.dockerContainer)
                },
                feed: EngineEventFeedClient(),
                eventID: { $0.id },
                reportSince: began)
            let events = try await bus.subscribe(filter).events
            // An engine that does not answer is said, rather than streamed silently.
            _ = try await ClientHealthCheck.ping(timeout: .seconds(10))
            // A reader that went away ends this quietly, as it would end `docker events`.
            signal(SIGPIPE, SIG_IGN)
            for await event in events {
                let line = try template.map { try $0.render(event.message) } ?? Self.text(event)
                // Each line as it happens: a reader waits on it, and stdout to a pipe is buffered.
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
                } catch {
                    return
                }
            }
            // The stream ends only when this reader fell behind and was dropped.
            throw ContainerizationError(.internalError, message: "events stopped: this reader fell behind")
        }

        /// Docker's line for an event without a template: its time, type, action and actor,
        /// then the attributes sorted.
        static func text(_ event: DockerEvent, timeZone: TimeZone = .current) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = timeZone
            var line = "\(formatter.string(from: event.time)) \(event.type) \(event.action) \(event.actorID)"
            if !event.attributes.isEmpty {
                line += " (" + event.attributes.keys.sorted().map { "\($0)=\(event.attributes[$0] ?? "")" }.joined(separator: ", ") + ")"
            }
            return line
        }
    }
}
