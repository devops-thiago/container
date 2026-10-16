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

/// `GET /containers/{id}/top`'s answer.
public struct DockerTopResponse: Codable, Sendable, Equatable {
    public var Titles: [String]
    public var Processes: [[String]]
}

/// `ps` output as `top` answers it.
public enum DockerTopParser {
    /// Splits `output` as dockerd does: the first line's words are the titles, and each other
    /// line has as many fields, the last of which takes the rest of the line, since a command
    /// has spaces in it. A table without a `PID` column is refused, as dockerd refuses it.
    public static func parse(_ output: String) throws(DockerAPIError) -> DockerTopResponse {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let titles = fields(lines.first ?? "")
        guard titles.contains("PID") else {
            throw .internalError("Couldn't find PID field in ps output")
        }
        var processes: [[String]] = []
        for line in lines.dropFirst() {
            let parts = fields(line)
            guard !parts.isEmpty else { continue }
            if parts.count < titles.count {
                processes.append(parts)
                continue
            }
            processes.append(Array(parts.prefix(titles.count - 1)) + [parts.dropFirst(titles.count - 1).joined(separator: " ")])
        }
        return DockerTopResponse(Titles: titles, Processes: processes)
    }

    /// The words of `line`, split on ASCII whitespace only, as dockerd splits them.
    static func fields(_ line: Substring) -> [String] {
        line.split(whereSeparator: { [" ", "\t", "\r", "\u{0C}"].contains($0) }).map(String.init)
    }
}

/// `GET /containers/{id}/top`.
extension ContainerToolRoutes.Routes {
    /// `?ps_args=` (`-ef` by default). dockerd runs the host's `ps` and keeps the container's
    /// processes; a container here is a VM, so `ps` runs inside it, which needs the image to
    /// have one. One without answers 500 and says so. The listing includes that `ps` itself.
    func top(_ reference: String, _ request: DockerRequest) async throws -> DockerResponse {
        let container = try await running(reference)
        let given = request.query("ps_args") ?? ""
        let arguments = given.isEmpty ? ["-ef"] : given.split(separator: " ").map(String.init)
        let run: DockerCapturedRun
        do {
            run = try await DockerContainerCommand.run(engine, in: container.snapshot, ["ps"] + arguments)
        } catch let unavailable as DockerContainerCommand.Unavailable {
            throw DockerAPIError.internalError(Self.noPS(container, unavailable.message))
        }
        guard run.status == 0 else {
            if run.status == DockerContainerCommand.notFoundStatus {
                throw DockerAPIError.internalError(Self.noPS(container, run.reason))
            }
            throw DockerAPIError.internalError("ps: \(run.reason.isEmpty ? "exit status \(run.status)" : run.reason)")
        }
        return try .json(try DockerTopParser.parse(run.stdoutText))
    }

    static func noPS(_ container: DockerContainer, _ reason: String) -> String {
        "SiliconShip lists a container's processes by running ps inside it, and ps could not run in container \(container.dockerID)"
            + (reason.isEmpty ? "" : ": \(reason)")
    }
}
