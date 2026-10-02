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
import Yams

/// A YAML value the way a compose file means it: scalars kept as written, mappings in file
/// order with merge keys applied, and every value knowing where it came from.
///
/// Compose types a value by the key it sits under, not by how YAML would read it, so
/// `"8080:80"`, `22:22`, `yes` and `1.10` all stay the text the file has.
struct ComposeNode {
    enum Value {
        case null
        case scalar(String)
        case sequence([ComposeNode])
        case mapping([Entry])
    }

    struct Entry {
        let key: String
        let keyLocation: SourceLocation
        var value: ComposeNode
    }

    var value: Value
    let location: SourceLocation
    /// A plain scalar may be a number, a boolean or nothing at all; one written in quotes
    /// or as a block is text whatever it looks like.
    let plain: Bool

    init(_ value: Value, at location: SourceLocation, plain: Bool = true) {
        self.value = value
        self.location = location
        self.plain = plain
    }
}

extension ComposeNode {
    /// Parse one compose document. An empty document is an empty mapping: an override file
    /// with nothing in it changes nothing.
    static func parse(yaml: String, file: String) throws -> ComposeNode {
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch let error as YamlError {
            throw ComposeError(Self.describe(error), at: Self.location(of: error, file: file))
        }
        guard let root else {
            return ComposeNode(.mapping([]), at: SourceLocation(file: file, line: 1, column: 1))
        }
        return try ComposeNode(root, file: file)
    }

    private static func describe(_ error: YamlError) -> String {
        switch error {
        case .scanner(_, let problem, _, _), .parser(_, let problem, _, _), .composer(_, let problem, _, _):
            return "not valid YAML: \(problem)"
        case .duplicatedKeysInMapping(let duplicates, _):
            return "not valid YAML: the key \(duplicates.map { "'\($0)'" }.joined(separator: ", ")) appears more than once in one mapping"
        default:
            return "not valid YAML: \(error)"
        }
    }

    private static func location(of error: YamlError, file: String) -> SourceLocation? {
        switch error {
        case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
            return SourceLocation(file: file, line: mark.line, column: mark.column)
        case .duplicatedKeysInMapping(_, let context):
            return SourceLocation(file: file, line: context.mark.line, column: context.mark.column)
        default:
            return nil
        }
    }

    private init(_ node: Node, file: String) throws {
        let location = SourceLocation(file: file, line: node.mark?.line ?? 1, column: node.mark?.column ?? 1)
        // Compose's own tags change how files merge. Reading past one would merge the
        // files differently from what the author asked for.
        let tag = node.tag.rawValue
        if tag == "!reset" || tag == "!override" {
            throw ComposeError(
                "the \(tag) tag is not supported: files merge key by key, so leave the setting out of the earlier file instead",
                at: location)
        }
        switch node {
        case .scalar(let scalar):
            let plain = scalar.style == .plain || scalar.style == .any
            if plain, Self.nullSpellings.contains(scalar.string) {
                self.init(.null, at: location)
            } else {
                self.init(.scalar(scalar.string), at: location, plain: plain)
            }
        case .sequence(let sequence):
            self.init(.sequence(try sequence.map { try ComposeNode($0, file: file) }), at: location)
        case .mapping(let mapping):
            self.init(.mapping(try Self.entries(of: mapping, file: file)), at: location)
        case .alias:
            // The parser resolves aliases while it composes; one left over names nothing.
            throw ComposeError("not valid YAML: an alias with nothing to refer to", at: location)
        }
    }

    private static let nullSpellings: Set<String> = ["", "~", "null", "Null", "NULL"]

    /// A mapping's entries with its merge keys (`<<`) applied: what the mapping says itself
    /// wins, then each merged mapping in the order given, the first to name a key keeping it.
    private static func entries(of mapping: Node.Mapping, file: String) throws -> [Entry] {
        var own: [Entry] = []
        var merged: [Entry] = []
        for pair in mapping {
            guard case .scalar(let key) = pair.key else {
                let mark = pair.key.mark
                throw ComposeError(
                    "a mapping key has to be text",
                    at: SourceLocation(file: file, line: mark?.line ?? 1, column: mark?.column ?? 1))
            }
            let keyLocation = SourceLocation(file: file, line: key.mark?.line ?? 1, column: key.mark?.column ?? 1)
            let isMerge = key.string == "<<" && (key.style == .plain || key.style == .any)
            guard isMerge else {
                own.append(Entry(key: key.string, keyLocation: keyLocation, value: try ComposeNode(pair.value, file: file)))
                continue
            }
            let source = try ComposeNode(pair.value, file: file)
            switch source.value {
            case .mapping(let entries):
                merged.append(contentsOf: entries)
            case .sequence(let items):
                for item in items {
                    guard case .mapping(let entries) = item.value else {
                        throw ComposeError("a merge key (<<) takes a mapping or a list of mappings", at: item.location)
                    }
                    merged.append(contentsOf: entries)
                }
            case .null:
                break
            case .scalar:
                throw ComposeError("a merge key (<<) takes a mapping or a list of mappings", at: source.location)
            }
        }
        var seen = Set(own.map(\.key))
        for entry in merged where seen.insert(entry.key).inserted {
            own.append(entry)
        }
        return own
    }
}

extension ComposeNode {
    var isNull: Bool {
        if case .null = value { return true }
        return false
    }

    var scalar: String? {
        if case .scalar(let text) = value { return text }
        return nil
    }

    var sequence: [ComposeNode]? {
        if case .sequence(let items) = value { return items }
        return nil
    }

    var mapping: [Entry]? {
        if case .mapping(let entries) = value { return entries }
        return nil
    }

    /// What kind of value this is, for a message about one that was expected to be another.
    var kind: String {
        switch value {
        case .null: return "nothing"
        case .scalar: return "a value"
        case .sequence: return "a list"
        case .mapping: return "a mapping"
        }
    }

    subscript(key: String) -> ComposeNode? {
        mapping?.first { $0.key == key }?.value
    }

    /// The same tree with every scalar passed through `transform`. Keys are left alone.
    func mapScalars(_ transform: (String, ComposeNode) throws -> String) rethrows -> ComposeNode {
        var copy = self
        switch value {
        case .null:
            break
        case .scalar(let text):
            copy.value = .scalar(try transform(text, self))
        case .sequence(let items):
            copy.value = .sequence(try items.map { try $0.mapScalars(transform) })
        case .mapping(let entries):
            copy.value = .mapping(
                try entries.map { entry in
                    var entry = entry
                    entry.value = try entry.value.mapScalars(transform)
                    return entry
                })
        }
        return copy
    }
}
