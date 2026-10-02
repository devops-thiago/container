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

/// The env-file format compose reads: `.env` beside the compose file, `--env-file`, and a
/// service's `env_file`.
///
/// One `KEY=value` per line, with an optional `export`. A value in single quotes is taken
/// as written; in double quotes it may span lines and use `\n`, `\t`, `\"` and `\\`;
/// unquoted, it ends at a ` #` comment. Double-quoted and unquoted values substitute
/// `${VAR}` from the environment and from the lines above. A name with no `=` has no value
/// of its own: it takes the environment's, if there is one.
enum DotEnv {
    struct Entry: Equatable {
        let key: String
        /// nil for a name written without `=`.
        let value: String?
    }

    static func parse(_ text: String, file: String, lookup: @escaping (String) -> String? = { _ in nil }) throws -> [Entry] {
        var entries: [Entry] = []
        var defined: [String: String] = [:]
        var interpolator = Interpolator(lookup: { name in lookup(name) ?? defined[name] })
        interpolator.strict = false

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            var line = Substring(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
            if lineNumber == 1, line.hasPrefix("\u{FEFF}") { line = line.dropFirst() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export"), let afterExport = line.dropFirst("export".count).first, afterExport == " " || afterExport == "\t" {
                line = Substring(line.dropFirst("export".count).trimmingCharacters(in: .whitespaces))
            }

            guard let equals = line.firstIndex(of: "=") else {
                // A name alone, with nothing after it but a comment.
                let word = line.prefix { $0 != " " && $0 != "\t" }
                let name = String(word)
                let after = line[word.endIndex...].trimmingCharacters(in: .whitespaces)
                try check(name: after.isEmpty || after.hasPrefix("#") ? name : String(line), file: file, line: lineNumber)
                entries.append(Entry(key: name, value: nil))
                continue
            }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            try check(name: name, file: file, line: lineNumber)
            let raw = Substring(line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" })

            let value: String
            if let quote = raw.first, quote == "\"" || quote == "'" {
                // A quoted value runs to its closing quote, on this line or a later one.
                var body = String(raw.dropFirst())
                var closed = closingQuote(quote, in: body)
                while closed == nil, index < lines.count {
                    body += "\n" + lines[index]
                    index += 1
                    closed = closingQuote(quote, in: body)
                }
                guard let closed else {
                    throw ComposeError(
                        "the value of \(name) opens a quote that is never closed",
                        at: SourceLocation(file: file, line: lineNumber, column: 1))
                }
                let quoted = String(body[..<closed])
                value = quote == "'" ? quoted : try interpolator.interpolate(unescape(quoted))
            } else {
                var unquoted = String(raw)
                if let comment = unquoted.range(of: " #") ?? unquoted.range(of: "\t#") {
                    unquoted = String(unquoted[..<comment.lowerBound])
                }
                value = try interpolator.interpolate(unquoted.trimmingCharacters(in: .whitespaces))
            }
            defined[name] = value
            entries.append(Entry(key: name, value: value))
        }
        return entries
    }

    private static func check(name: String, file: String, line: Int) throws {
        let valid =
            !name.isEmpty
            && name.allSatisfy { $0 == "_" || $0 == "." || $0 == "-" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard valid else {
            throw ComposeError(
                "'\(name)' is not a variable name; a line is KEY=value, a # comment, or empty",
                at: SourceLocation(file: file, line: line, column: 1))
        }
    }

    /// Where the quote that closes a value sits in `body`, which starts just after the
    /// opening one. A backslash protects the character after it in double quotes.
    private static func closingQuote(_ quote: Character, in body: String) -> String.Index? {
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "\\", quote == "\"" {
                index = body.index(after: index)
                guard index < body.endIndex else { return nil }
            } else if character == quote {
                return index
            }
            index = body.index(after: index)
        }
        return nil
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var escaped = false
        for character in text {
            guard escaped else {
                if character == "\\" { escaped = true } else { result.append(character) }
                continue
            }
            escaped = false
            switch character {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\"", "\\": result.append(character)
            // `\$` keeps the dollar sign from starting a substitution.
            case "$": result.append("$$")
            default:
                result.append("\\")
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}
