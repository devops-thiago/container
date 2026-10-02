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

/// Splitting a command written as one string into its arguments, the way a compose file's
/// `command: bundle exec thin -p 3000` is read: on whitespace, with single quotes taking
/// text as written, double quotes allowing `\"` and `\\`, and a backslash outside quotes
/// protecting the next character. Nothing is expanded: no variables, no globs, no
/// backticks.
enum ShellWords {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false

        for character in text {
            if escaped {
                // Inside double quotes a backslash only protects the characters that mean
                // something there; before anything else it is a backslash.
                if quote == "\"", !["\"", "\\", "$", "`", "\n"].contains(character) {
                    current.append("\\")
                }
                if character != "\n" { current.append(character) }
                escaped = false
                continue
            }
            switch (character, quote) {
            case ("\\", nil), ("\\", "\""):
                escaped = true
                inWord = true
            case ("'", nil), ("\"", nil):
                quote = character
                inWord = true
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case (_, nil) where character.isWhitespace:
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(character)
                inWord = true
            }
        }
        if let quote {
            throw Failure(message: "a quote (\(quote)) is opened and never closed")
        }
        guard !escaped else {
            throw Failure(message: "ends with a backslash that protects nothing")
        }
        if inWord { words.append(current) }
        return words
    }

    /// One argument written so that a shell reads it back as the same text.
    static func quote(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let plain = word.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_-./:=@,+%".contains(character))
        }
        guard !plain else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
