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

/// A boolean as the Docker CLI's flags take one (`--sig-proxy=false`): Go's `ParseBool`
/// spellings.
public struct DockerBool: ExpressibleByArgument, Sendable, Equatable, CustomStringConvertible {
    public let value: Bool

    public init(_ value: Bool) {
        self.value = value
    }

    public init?(argument: String) {
        switch argument {
        case "1", "t", "T", "TRUE", "true", "True": value = true
        case "0", "f", "F", "FALSE", "false", "False": value = false
        default: return nil
        }
    }

    public var description: String { value ? "true" : "false" }
}
