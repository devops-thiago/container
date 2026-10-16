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

/// dockerd's filter matching (its `filters.Args`), shared by the image, volume and network
/// routes.
enum DockerFilters {
    /// Refuses a filter outside `accepted`, in dockerd's words. One dockerd has and this service
    /// does not is named as unsupported rather than invalid.
    static func validate(_ filters: [String: [String]], accepted: Set<String>, unsupported: Set<String> = []) throws(DockerAPIError) {
        for key in filters.keys.sorted() where !accepted.contains(key) {
            if unsupported.contains(key) {
                throw .badRequest("the '\(key)' filter is not supported")
            }
            throw .badRequest("invalid filter '\(key)'")
        }
    }

    /// A boolean filter, as `GetBoolOrDefault` reads one: `true`/`1` or `false`/`0`, and not
    /// both.
    static func bool(_ filters: [String: [String]], _ key: String, default value: Bool) throws(DockerAPIError) -> Bool {
        guard let values = filters[key] else { return value }
        let isTrue = values.contains("true") || values.contains("1")
        let isFalse = values.contains("false") || values.contains("0")
        guard isTrue != isFalse else {
            throw .badRequest("invalid filter '\(key)=[\(values.joined(separator: " "))]'")
        }
        return isTrue
    }

    /// `MatchKVList`: every `key` or `key=value` holds in `labels`. True without values.
    static func labelsMatch(_ values: [String]?, _ labels: [String: String]) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.allSatisfy { condition in
            let parts = condition.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let value = labels[String(parts[0])] else { return false }
            return parts.count == 1 || value == parts[1]
        }
    }

    /// `label` and `label!` together, as a prune reads them: every `label` holds, and the
    /// `label!` conditions do not all hold.
    static func pruneLabelsMatch(_ filters: [String: [String]], _ labels: [String: String]) -> Bool {
        guard labelsMatch(filters["label"], labels) else { return false }
        guard let excluded = filters["label!"], !excluded.isEmpty else { return true }
        return !labelsMatch(excluded, labels)
    }

    /// `Match`: true without values; otherwise a value equals `source` or, as an unanchored
    /// regular expression, is found in it.
    static func patternMatch(_ values: [String]?, _ source: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains { value in
            value == source || ((try? Regex(value)).map { source.contains($0) } ?? false)
        }
    }

    /// `ExactMatch`: true without values; otherwise a value equals `source`.
    static func exactMatch(_ values: [String]?, _ source: String) -> Bool {
        guard let values, !values.isEmpty else { return true }
        return values.contains(source)
    }

    struct BadPattern: Error {}

    /// Go's `path.Match`: `*` is any run of characters but `/`, `?` one character but `/`,
    /// `[…]` a class with ranges and `^` negation, `\` escapes the next character.
    static func glob(_ pattern: String, _ name: String) throws(BadPattern) -> Bool {
        try glob(Array(pattern), 0, Array(name), 0)
    }

    private static func glob(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) throws(BadPattern) -> Bool {
        var pi = pi
        var si = si
        while pi < p.count {
            switch p[pi] {
            case "*":
                // Runs of stars are one star.
                while pi < p.count && p[pi] == "*" { pi += 1 }
                if pi == p.count { return !s[si...].contains("/") }
                var next = si
                while next <= s.count {
                    if try glob(p, pi, s, next) { return true }
                    if next == s.count || s[next] == "/" { break }
                    next += 1
                }
                // The rest of the pattern is still checked, so a bad one is reported.
                _ = try glob(p, pi, [], 0)
                return false
            case "?":
                guard si < s.count, s[si] != "/" else { return false }
                pi += 1
                si += 1
            case "[":
                let (matched, end) = try matchClass(p, pi, si < s.count ? s[si] : nil)
                guard si < s.count, matched else { return false }
                pi = end
                si += 1
            case "\\":
                pi += 1
                guard pi < p.count else { throw BadPattern() }
                guard si < s.count, s[si] == p[pi] else { return false }
                pi += 1
                si += 1
            default:
                guard si < s.count, s[si] == p[pi] else { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    /// Whether `character` is in the class starting at `start` (a `[`), and where the class ends.
    private static func matchClass(_ p: [Character], _ start: Int, _ character: Character?) throws(BadPattern) -> (Bool, Int) {
        var i = start + 1
        var negated = false
        if i < p.count && p[i] == "^" {
            negated = true
            i += 1
        }
        var matched = false
        var first = true
        while true {
            guard i < p.count else { throw BadPattern() }
            if p[i] == "]" {
                // An empty class is a bad pattern in Go.
                guard !first else { throw BadPattern() }
                break
            }
            first = false
            var low = p[i]
            if low == "\\" {
                i += 1
                guard i < p.count else { throw BadPattern() }
                low = p[i]
            }
            i += 1
            var high = low
            if i + 1 < p.count && p[i] == "-" && p[i + 1] != "]" {
                i += 1
                high = p[i]
                if high == "\\" {
                    i += 1
                    guard i < p.count else { throw BadPattern() }
                    high = p[i]
                }
                i += 1
            }
            if let character, low <= character && character <= high { matched = true }
        }
        return (character != "/" && matched != negated, i + 1)
    }
}
