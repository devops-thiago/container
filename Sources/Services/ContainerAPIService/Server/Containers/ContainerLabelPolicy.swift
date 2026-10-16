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

import ContainerizationError
import Foundation

/// Which of a container's labels may change after it is made.
///
/// A container's labels are set at create and read back by everything that manages it, so by
/// default none changes. An embedder that keeps a container's name in a label, as a Docker
/// API does, names that label here: it is then the one label a client may set, a container's
/// events carry it as the container's name, and no two containers hold the same value in it.
/// Every other label stays as it was made, ownership and identity labels included.
public struct ContainerLabelPolicy: Sendable, Equatable {
    /// The label holding a container's name, if the embedder keeps one.
    public var nameKey: String?

    public init(nameKey: String? = nil) {
        self.nameKey = nameKey
    }

    /// No label may change.
    public static let fixed = ContainerLabelPolicy()

    /// The longest value a label set after create may have, in bytes.
    public static let maximumValueBytes = 255

    /// The keys a client may set.
    public var mutableKeys: Set<String> {
        nameKey.map { [$0] } ?? []
    }

    /// The container's name: the name label when there is one, otherwise its ID.
    public func name(id: String, labels: [String: String]) -> String {
        nameLabel(labels) ?? id
    }

    /// The name label's value, when the policy names one and the container has it.
    public func nameLabel(_ labels: [String: String]) -> String? {
        nameKey.flatMap { labels[$0] }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The container among `others` that already holds a name a container `id` with `labels`
    /// would have, and that name, as Docker refuses a name in use: its name label taken as
    /// another's label or ID, or, with `checkingID`, its ID taken as another's name label. nil
    /// when it is free, and always when the policy keeps no name.
    public func holder(
        ofNameFor id: String, labels: [String: String], among others: [(id: String, labels: [String: String])], checkingID: Bool
    ) -> (holder: String, name: String)? {
        guard nameKey != nil else { return nil }
        let name = nameLabel(labels)
        for other in others where other.id != id {
            let otherName = nameLabel(other.labels)
            if let name, name == other.id || name == otherName {
                return (other.id, name)
            }
            if checkingID, let otherName, otherName == id {
                return (other.id, id)
            }
        }
        return nil
    }

    /// Refuses a change this policy does not allow, before anything is changed.
    public func validate(_ labels: [String: String]) throws {
        guard !labels.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "no labels to set")
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            guard mutableKeys.contains(key) else {
                throw ContainerizationError(.invalidArgument, message: "label \(key) cannot be changed after a container is made")
            }
            guard !value.isEmpty, value.utf8.count <= Self.maximumValueBytes else {
                throw ContainerizationError(
                    .invalidArgument, message: "label \(key) must have a value of 1 to \(Self.maximumValueBytes) bytes")
            }
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ContainerizationError(.invalidArgument, message: "label \(key) cannot hold control characters")
            }
        }
    }
}
