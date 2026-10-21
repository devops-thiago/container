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

/// Docker's bool flags with a value (`run --sig-proxy=false`). ArgumentParser has no option
/// that is a flag alone and takes a value only after `=`: it either never takes one or also
/// takes the next argument, which for `run --sig-proxy false alpine` would eat the image
/// Docker sees there. So the flag is a flag, and before parsing the `=` form of a `run` is
/// renamed to a hidden option of its own; what reaches the container's arguments is named
/// back.
enum DockerSpellings {
    static let sigProxyValue = "sig-proxy-value"
    private static let dockerPrefix = "--sig-proxy="
    private static let hiddenPrefix = "--\(sigProxyValue)="

    /// `arguments` with `run`'s `--sig-proxy=<value>` given to the hidden option.
    static func rewrite(_ arguments: [String]) -> [String] {
        guard let verb = runIndex(arguments) else { return arguments }
        return arguments.enumerated().map { index, argument in
            index > verb && argument.hasPrefix(dockerPrefix) ? hiddenPrefix + argument.dropFirst(dockerPrefix.count) : argument
        }
    }

    /// An argument as it was written before `rewrite`.
    static func restore(_ argument: String) -> String {
        argument.hasPrefix(hiddenPrefix) ? dockerPrefix + argument.dropFirst(hiddenPrefix.count) : argument
    }

    /// Where `run` is, when the command is `run` or `container run`.
    static func runIndex(_ arguments: [String]) -> Int? {
        var index = arguments.startIndex
        // The root's own option comes before the command.
        while index < arguments.endIndex, arguments[index] == "--debug" { index += 1 }
        if index < arguments.endIndex, arguments[index] == "container" { index += 1 }
        return index < arguments.endIndex && arguments[index] == "run" ? index : nil
    }

    /// Docker's words for a bool flag given something else.
    static func invalidBool(_ value: String, flag: String) -> String {
        "invalid argument \"\(value)\" for \"\(flag)\" flag: strconv.ParseBool: parsing \"\(value)\": invalid syntax"
    }
}

extension Application {
    /// The command `arguments` name, with Docker's spellings that ArgumentParser cannot take
    /// as written (`DockerSpellings`). Every parse of a command line goes through here.
    static func parseDockerSpellings(_ arguments: [String]) throws -> any ParsableCommand {
        let command = try parseAsRoot(DockerSpellings.rewrite(arguments))
        guard var run = command as? ContainerRun else { return command }
        run.arguments = run.arguments.map(DockerSpellings.restore)
        return run
    }
}
