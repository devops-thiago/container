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

import ContainerResource
import ContainerizationError
import Foundation

/// The filters of one list request, with their patterns compiled once rather than for
/// every container the request looks at.
struct ContainerListMatcher {
    private let ids: [String]
    private let status: RuntimeStatus?
    private let name: Regex<AnyRegexOutput>?
    private let labels: [(key: String, regex: Regex<AnyRegexOutput>)]

    init(_ filters: ContainerListFilters) throws {
        ids = filters.ids
        status = filters.status
        name = try filters.name.map { try Self.compile($0, for: "name") }
        labels = try filters.labels.map { key, pattern in
            (key: key, regex: try Self.compile(pattern, for: key))
        }
    }

    /// Whether `snapshot` satisfies every filter. A label the container does not carry is
    /// matched as an empty value: that is what lets a negation pattern admit it and a
    /// positive one reject it.
    func admits(_ snapshot: ContainerSnapshot) -> Bool {
        if !ids.isEmpty, !ids.contains(snapshot.id) {
            return false
        }
        if let status, snapshot.status != status {
            return false
        }
        if let name, !snapshot.id.contains(name) {
            return false
        }
        return labels.allSatisfy { key, regex in
            (snapshot.configuration.labels[key] ?? "").contains(regex)
        }
    }

    private static func compile(_ pattern: String, for field: String) throws -> Regex<AnyRegexOutput> {
        do {
            return try Regex(pattern)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "failed to compile regex '\(pattern)' for \(field)", cause: error)
        }
    }
}
