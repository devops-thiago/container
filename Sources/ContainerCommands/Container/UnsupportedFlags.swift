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

import ContainerAPIClient
import Foundation

extension Flags.Unsupported {
    /// The line written for one ignored flag.
    public static func warning(for flag: String) -> String {
        "\(flag) is not supported by this engine and was ignored"
    }

    /// Report every flag that was given, one line each on stderr, before any progress
    /// output. The exit status is unaffected: the point is that the command still runs.
    public func warnAboutGivenFlags() {
        let colour = isatty(FileHandle.standardError.fileDescriptor) == 1
        for flag in given {
            let line = Self.warning(for: flag)
            let text = colour ? "\u{001B}[33mWarning!\u{001B}[0m \(line)\n" : "Warning! \(line)\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
    }
}
