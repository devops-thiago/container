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
import ContainerizationError
import Foundation

extension Application {
    public struct ContainerInspect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more containers")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Print Docker's view of each: container, image or volume")
        var type: DockerObjectType?

        @Option(name: [.customShort("f"), .long], help: "Print Docker's view of each through a Go template, such as {{json .}}")
        var format: String?

        @Argument(help: "Container IDs to inspect")
        var containerIds: [String]

        public func validate() throws {
            _ = try dockerTemplate()
        }

        /// The template `--format` gives; none for `json`, which is the array printed without one.
        func dockerTemplate() throws -> DockerTemplate? {
            guard let format, format != "json" else { return nil }
            guard DockerTemplate.isTemplate(format) else {
                throw ValidationError("--format takes json or a template, such as {{json .}}")
            }
            do {
                return try DockerTemplate(format)
            } catch {
                throw ValidationError(error.description)
            }
        }

        public func run() async throws {
            guard type == nil && format == nil else {
                try await runDocker()
                return
            }
            let client = ContainerClient()
            let uniqueIds = Set(containerIds)
            let containers = try await client.list().filter {
                uniqueIds.contains($0.id)
            }

            if containers.count != uniqueIds.count {
                let found = Set(containers.map { $0.id })
                let missing = uniqueIds.subtracting(found).sorted()
                throw ContainerizationError(
                    .notFound,
                    message: "container not found: \(missing.joined(separator: ", "))"
                )
            }

            try Output.emit(Output.renderJSON(containers.map { ManagedContainer($0) }, options: .pretty))
        }
    }
}

extension Application.ContainerInspect {
    /// `docker inspect`: each object as the Docker API shows it, found ones printed before the
    /// names that found nothing fail the command, as dockerd's CLI does.
    func runDocker() async throws {
        let template = try dockerTemplate()
        let result = try await DockerInspection.lookup(containerIds, type: type)
        if template == nil || !result.found.isEmpty {
            print(try DockerInspection.render(result.found, template: template))
        }
        guard result.missing.isEmpty else {
            throw ContainerizationError(
                .notFound, message: result.missing.map { DockerInspection.notFound($0, type: type) }.joined(separator: "\n"))
        }
    }
}
