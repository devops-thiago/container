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
import Foundation

/// What `compose version` prints. Scripts written for `docker compose` run it to find out
/// whether compose is there, and read the number from one of its three forms.
public enum ComposeVersionReport {
    public enum Format: String, Sendable, CaseIterable, ExpressibleByArgument {
        case pretty
        case json
    }

    /// The format to print in: the one asked for, or the one `-f` names.
    ///
    /// Other compose tools spell `--format` as `-f` after `version`. Here `-f` is the compose
    /// file, wherever on the command line it is written, so `version -f json` arrives as a
    /// file named json. `version` reads no file, so a file that names a format is one.
    public static func format(named: Format?, files: [String]) -> Format {
        named ?? files.last.flatMap(Format.init(rawValue:)) ?? .pretty
    }

    /// - Parameters:
    ///   - line: the version as a sentence, with the build beside it.
    ///   - version: the number alone.
    ///   - short: print the number and nothing else, whatever the format.
    public static func render(line: String, version: String, short: Bool, format: Format) -> String {
        if short { return version }
        switch format {
        case .pretty:
            return line
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = (try? encoder.encode(["version": version])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
