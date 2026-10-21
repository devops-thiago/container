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

/// A Docker `--format` template: Go's text/template, in the forms tools that drive the Docker
/// CLI send. Text, `{{.}}`, `{{.Field.Field}}`, and `json` of either (`{{json .}}`), with
/// `{{-` and `-}}` trimming the space beside them. Anything else is refused rather than
/// printed wrong.
///
/// Fields are looked up in the value's JSON, which for Docker's views has the names Docker's
/// templates use.
public struct DockerTemplate: Sendable, Equatable {
    enum Part: Sendable, Equatable {
        case text(String)
        case field([String], json: Bool)
    }

    let parts: [Part]

    /// Whether a `--format` value is a template rather than the name of a format.
    public static func isTemplate(_ text: String) -> Bool {
        text.contains("{{")
    }

    public init(_ source: String) throws(DockerTemplateError) {
        var parts: [Part] = []
        var rest = Substring(source)
        var trimNextText = false
        while let open = rest.range(of: "{{") {
            var text = String(rest[..<open.lowerBound])
            if trimNextText { text = String(text.drop(while: \.isWhitespace)) }
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw DockerTemplateError(source: source, reason: "unclosed action")
            }
            var action = Substring(rest[open.upperBound..<close.lowerBound])
            if action.hasPrefix("- ") || action == "-" {
                action = action.dropFirst()
                while text.last?.isWhitespace == true { text.removeLast() }
            }
            trimNextText = false
            if action.hasSuffix(" -") {
                action = action.dropLast()
                trimNextText = true
            }
            if !text.isEmpty { parts.append(.text(text)) }
            parts.append(try Self.part(action, source: source))
            rest = rest[close.upperBound...]
        }
        let tail = trimNextText ? String(rest.drop(while: \.isWhitespace)) : String(rest)
        if !tail.isEmpty { parts.append(.text(tail)) }
        self.parts = parts
    }

    private static func part(_ action: Substring, source: String) throws(DockerTemplateError) -> Part {
        let words = action.split(whereSeparator: \.isWhitespace)
        switch words.count {
        case 1:
            return .field(try path(words[0], action: action, source: source), json: false)
        case 2 where words[0] == "json":
            return .field(try path(words[1], action: action, source: source), json: true)
        default:
            throw DockerTemplateError(source: source, reason: "unsupported action {{\(action)}}")
        }
    }

    /// `.` as no keys, `.A.B` as `A` then `B`.
    private static func path(_ word: Substring, action: Substring, source: String) throws(DockerTemplateError) -> [String] {
        guard word.first == "." else {
            throw DockerTemplateError(source: source, reason: "unsupported action {{\(action)}}")
        }
        guard word != "." else { return [] }
        let keys = word.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        for key in keys where key.isEmpty || !key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            throw DockerTemplateError(source: source, reason: "unsupported action {{\(action)}}")
        }
        return keys.map(String.init)
    }

    /// The template applied to `value`.
    public func render(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var output = ""
        for part in parts {
            switch part {
            case .text(let text):
                output += text
            case .field([], json: true):
                // The value as it encodes, its fields in their own order.
                output += String(decoding: data, as: UTF8.self)
            case .field(let path, let json):
                let found = Self.lookup(path, in: root)
                output += json ? try Self.json(found) : Self.text(found)
            }
        }
        return output
    }

    /// What `path` names in `root`; nil when a key is missing.
    static func lookup(_ path: [String], in root: Any) -> Any? {
        var current: Any? = root
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    static func json(_ value: Any?) throws -> String {
        guard let value else { return "null" }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// A value as Go's template prints one: `<no value>` for a missing key, maps as
    /// `map[k:v]`, lists as `[a b]`.
    static func text(_ value: Any?) -> String {
        guard let value else { return "<no value>" }
        switch value {
        case is NSNull:
            return "<nil>"
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let list as [Any]:
            return "[" + list.map { text($0) }.joined(separator: " ") + "]"
        case let map as [String: Any]:
            return "map[" + map.keys.sorted().map { "\($0):\(text(map[$0]))" }.joined(separator: " ") + "]"
        default:
            return "\(value)"
        }
    }
}

public struct DockerTemplateError: Error, CustomStringConvertible, Equatable {
    public let source: String
    public let reason: String

    public var description: String {
        "template \(source): \(reason)"
    }
}
