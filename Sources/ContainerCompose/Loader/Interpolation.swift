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

/// Variable substitution as compose files use it: `$VAR`, `${VAR}`, and the braced forms
/// with a default (`:-`, `-`), a requirement (`:?`, `?`) or an alternative (`:+`, `+`).
/// `$$` is a dollar sign.
struct Interpolator {
    /// The value of a variable, or nil when it is not set.
    let lookup: (String) -> String?
    /// Called with the name of each variable that was used without a default and is not
    /// set. Such a variable reads as an empty string.
    var onUnset: (String) -> Void = { _ in }
    /// Whether a `$` that starts nothing recognizable is an error (compose files) or a
    /// dollar sign (env files, where passwords have them).
    var strict = true

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    func interpolate(_ text: String, depth: Int = 0) throws -> String {
        try Task.checkCancellation()
        guard depth < 64 else { throw Failure(message: "interpolation nesting exceeds 64 levels") }
        guard text.contains("$") else { return text }
        var result = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            try append(rest[..<dollar], to: &result)
            try Task.checkCancellation()
            rest = rest[rest.index(after: dollar)...]
            guard let next = rest.first else {
                try literalDollar(in: text, into: &result)
                break
            }
            if next == "$" {
                result.append("$")
                rest = rest.dropFirst()
            } else if next == "{" {
                guard let close = Self.closingBrace(of: rest) else {
                    guard strict else {
                        result.append("$")
                        continue
                    }
                    throw Failure(message: "invalid interpolation in \"\(text)\": '${' is never closed")
                }
                let body = rest[rest.index(after: rest.startIndex)..<close]
                if let value = try substitute(braced: body, in: text, depth: depth) {
                    try append(value, to: &result)
                } else {
                    try append("${" + body + "}", to: &result)
                }
                rest = rest[rest.index(after: close)...]
            } else if Self.startsName(next) {
                let name = rest.prefix(while: Self.continuesName)
                try append(value(of: String(name)), to: &result)
                rest = rest[name.endIndex...]
            } else {
                try literalDollar(in: text, into: &result)
            }
        }
        try append(rest, to: &result)
        return result
    }

    private func append<S: StringProtocol>(_ value: S, to result: inout String) throws {
        guard value.utf8.count <= ComposeInput.maximumExpandedBytes - result.utf8.count else {
            throw Failure(message: "interpolated text exceeds the 8 MiB compose input budget")
        }
        result += value
    }

    private func literalDollar(in text: String, into result: inout String) throws {
        guard !strict else {
            throw Failure(
                message: "invalid interpolation in \"\(text)\": a '$' has to be followed by a variable name; write '$$' for a dollar sign")
        }
        result.append("$")
    }

    private func value(of name: String) -> String {
        if let value = lookup(name) { return value }
        onUnset(name)
        return ""
    }

    /// The text for `${body}`; nil when the body is not a substitution and the caller is
    /// lenient, so the text stays as written.
    private func substitute(braced body: Substring, in text: String, depth: Int) throws -> String? {
        let name = body.prefix(while: Self.continuesName)
        guard let first = name.first, Self.startsName(first) else {
            guard strict else { return nil }
            throw Failure(message: "invalid interpolation in \"\(text)\": '${\(body)}' does not name a variable")
        }
        let variable = String(name)
        let modifier = body[name.endIndex...]
        guard !modifier.isEmpty else { return value(of: variable) }

        let current = lookup(variable)
        let operators: [(String, Bool)] = [(":-", true), ("-", false), (":?", true), ("?", false), (":+", true), ("+", false)]
        for (symbol, emptyCountsAsUnset) in operators where modifier.hasPrefix(symbol) {
            let argument = String(modifier.dropFirst(symbol.count))
            let isSet = current.map { !(emptyCountsAsUnset && $0.isEmpty) } ?? false
            switch symbol.last {
            case "-":
                return isSet ? current : try interpolate(argument, depth: depth + 1)
            case "?":
                guard isSet else {
                    let reason = try interpolate(argument, depth: depth + 1)
                    throw Failure(message: "required variable \(variable) is missing a value" + (reason.isEmpty ? "" : ": \(reason)"))
                }
                return current
            default:
                return isSet ? try interpolate(argument, depth: depth + 1) : ""
            }
        }
        guard strict else { return nil }
        throw Failure(message: "invalid interpolation in \"\(text)\": '${\(body)}' is not a form compose knows")
    }

    /// The index of the `}` that closes the `{` at the start of `text`, with nested
    /// `${...}` counted.
    private static func closingBrace(of text: Substring) -> Substring.Index? {
        var depth = 0
        var index = text.startIndex
        var previous: Character?
        while index < text.endIndex {
            let character = text[index]
            if character == "{", index == text.startIndex || previous == "$" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            previous = character
            index = text.index(after: index)
        }
        return nil
    }

    private static func startsName(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && character.isLetter)
    }

    private static func continuesName(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
    }
}
