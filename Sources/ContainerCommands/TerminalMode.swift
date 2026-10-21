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
import Foundation

extension Application {
    /// Use the same parser as execution: a guest argument named `-it`, an option value,
    /// help or a detached command must not change the host terminal's input mode.
    ///
    /// - Parameter container: the container `start` would start, by the ID it was given; only
    ///   asked for a `start` that attaches stdin, whose terminal is the container's.
    static func terminalMode(
        arguments: [String],
        container: (String) async -> ContainerSnapshot? = { try? await ContainerClient().get(id: $0) }
    ) async -> String {
        guard let command = try? parseDockerSpellings(arguments) else { return "none" }
        switch command {
        case let command as ContainerExec:
            return command.processFlags.tty && command.processFlags.interactive && !command.detach ? "raw" : "none"
        case let command as ContainerRun:
            return command.processFlags.tty && command.processFlags.interactive && !command.managementFlags.detach ? "raw" : "none"
        case let command as MachineRun:
            return command.usesRawTerminal ? "raw" : "none"
        case let command as ContainerStart:
            guard command.interactive else { return "none" }
            // Unknown metadata is not evidence of a non-TTY container. The launcher must
            // refuse this attempt before it starts an interactive session in line mode.
            guard let snapshot = await container(command.containerId) else { return "unavailable" }
            return command.usesRawTerminal(snapshot) ? "raw" : "none"
        default:
            return "none"
        }
    }
}
