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
import ContainerResource

/// A `--format` value: one of the command's own formats, or a Docker template
/// (`{{json .}}`), which tools that drive the Docker CLI pass. Help lists only the formats.
public enum FormatOrTemplate: ExpressibleByArgument, Sendable, Equatable {
    case format(ListFormat)
    case template(Result<DockerTemplate, DockerTemplateError>)

    public init?(argument: String) {
        if let format = ListFormat(argument: argument) {
            self = .format(format)
        } else if DockerTemplate.isTemplate(argument) {
            // Refused in `validate()`, where the reason can be said.
            self = .template(Result { () throws(DockerTemplateError) in try DockerTemplate(argument) })
        } else {
            return nil
        }
    }

    public static var allValueStrings: [String] { ListFormat.allValueStrings }

    public var defaultValueDescription: String {
        switch self {
        case .format(let format): format.defaultValueDescription
        case .template: ""
        }
    }

    /// The template, or nil for a format; throws for a template that cannot be used.
    public func dockerTemplate() throws -> DockerTemplate? {
        guard case .template(let result) = self else { return nil }
        do {
            return try result.get()
        } catch {
            throw ValidationError(error.description)
        }
    }
}
