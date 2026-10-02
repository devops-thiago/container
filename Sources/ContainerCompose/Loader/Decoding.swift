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

/// What decoding one compose file needs to know beyond the file itself.
struct DecodeContext {
    /// Relative paths in a compose file are relative to this, whichever file names them.
    let projectDirectory: URL
    /// What `~` at the start of a path means.
    let homeDirectory: String
    let diagnostics: DiagnosticCollector

    func absolute(_ path: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = homeDirectory
        } else if expanded.hasPrefix("~/") {
            expanded = homeDirectory + expanded.dropFirst(1)
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return projectDirectory.appendingPathComponent(expanded).standardizedFileURL.path
    }
}

/// How a key that is not acted on is reported.
enum KeySupport {
    /// The project runs without it; say so once.
    case ignored(String)
    /// The project would not be what the file describes without it.
    case rejected(String)
}

/// One mapping being read key by key, so that whatever nobody asked for can be reported.
struct MappingReader {
    let path: String
    let location: SourceLocation
    private let entries: [ComposeNode.Entry]
    private var taken: Set<String> = []
    private let diagnostics: DiagnosticCollector

    /// nil, with an error recorded, when the node is not a mapping. Nothing at all reads
    /// as an empty mapping: `db:` with no body is a service with no settings.
    init?(_ node: ComposeNode, path: String, diagnostics: DiagnosticCollector) {
        switch node.value {
        case .mapping(let entries):
            self.entries = entries
        case .null:
            self.entries = []
        default:
            diagnostics.error(path, "expected a mapping, found \(node.kind)", at: node.location)
            return nil
        }
        self.path = path
        self.location = node.location
        self.diagnostics = diagnostics
    }

    func path(of key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    /// The value under `key`, marking the key as understood. A key written with no value
    /// (`key:`) is absent, unless `keepingNull` asks for it.
    mutating func take(_ key: String, keepingNull: Bool = false) -> ComposeNode? {
        taken.insert(key)
        guard let node = entries.first(where: { $0.key == key })?.value else { return nil }
        return node.isNull && !keepingNull ? nil : node
    }

    /// Every key and value, for mappings whose keys are names rather than settings.
    var all: [ComposeNode.Entry] { entries }

    /// Where `key` is written, for a message about the key rather than its value.
    func keyLocation(_ key: String) -> SourceLocation? {
        entries.first { $0.key == key }?.keyLocation
    }

    /// Where every key of the mapping is written.
    var keyLocations: [String: SourceLocation] {
        Dictionary(entries.map { ($0.key, $0.keyLocation) }) { first, _ in first }
    }

    /// Report the keys nobody took: extension fields (`x-`) pass, the ones in `known` are
    /// reported as that table says, and anything else is not a key compose has.
    func finish(known: [String: KeySupport] = [:]) {
        for entry in entries where !taken.contains(entry.key) && !entry.key.hasPrefix("x-") {
            let keyPath = path(of: entry.key)
            switch known[entry.key] {
            case .ignored(let reason):
                diagnostics.warn(keyPath, "ignored: \(reason)", at: entry.keyLocation)
            case .rejected(let reason):
                diagnostics.error(keyPath, "not supported on this engine\(reason.isEmpty ? "" : ": \(reason)")", at: entry.keyLocation)
            case nil:
                diagnostics.error(keyPath, "not a compose key", at: entry.keyLocation)
            }
        }
    }
}

// MARK: - Values

extension DecodeContext {
    /// A single value as text. Numbers and booleans are text too: `PORT: 8080` and
    /// `DEBUG: true` are the strings a container's environment gets.
    func text(_ node: ComposeNode, _ path: String) -> String? {
        guard let text = node.scalar else {
            diagnostics.error(path, "expected a value, found \(node.kind)", at: node.location)
            return nil
        }
        return text
    }

    func bool(_ node: ComposeNode, _ path: String) -> Bool? {
        guard let text = text(node, path) else { return nil }
        switch text.lowercased() {
        case "true", "yes", "on", "y": return true
        case "false", "no", "off", "n": return false
        default:
            diagnostics.error(path, "expected true or false, found '\(text)'", at: node.location)
            return nil
        }
    }

    func integer(_ node: ComposeNode, _ path: String) -> Int? {
        guard let text = text(node, path) else { return nil }
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
            diagnostics.error(path, "expected a whole number, found '\(text)'", at: node.location)
            return nil
        }
        return value
    }

    func number(_ node: ComposeNode, _ path: String) -> Double? {
        guard let text = text(node, path) else { return nil }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            diagnostics.error(path, "expected a number, found '\(text)'", at: node.location)
            return nil
        }
        return value
    }

    /// A duration such as `90s`, `1m30s` or `500ms`, in seconds. A bare number is seconds.
    func duration(_ node: ComposeNode, _ path: String) -> Double? {
        guard let text = text(node, path) else { return nil }
        guard let seconds = Self.seconds(text) else {
            diagnostics.error(path, "expected a duration such as 30s or 1m30s, found '\(text)'", at: node.location)
            return nil
        }
        return seconds
    }

    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let plain = Double(trimmed) { return plain >= 0 ? plain : nil }
        // Two-letter units first, so that "ms" is not read as "m" followed by "s".
        let units: [(String, Double)] = [
            ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("ms", 1e-3), ("s", 1), ("m", 60), ("h", 3600), ("d", 86400), ("w", 604800),
        ]
        var total = 0.0
        var rest = Substring(trimmed)
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            guard !digits.isEmpty, let value = Double(digits) else { return nil }
            rest = rest[digits.endIndex...]
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += value * unit.1
            rest = rest.dropFirst(unit.0.count)
        }
        return total
    }

    /// A size in bytes with an optional unit (`512m`, `1gb`, `2048`), kept as text for the
    /// engine's own parser, which reads the same spellings.
    func size(_ node: ComposeNode, _ path: String) -> String? {
        guard let text = text(node, path) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed[digits.endIndex...].trimmingCharacters(in: .whitespaces)
        let units: Set<String> = ["", "b", "k", "kb", "kib", "m", "mb", "mib", "g", "gb", "gib", "t", "tb", "tib", "p", "pb", "pib"]
        guard !digits.isEmpty, Double(digits) != nil, units.contains(unit) else {
            diagnostics.error(path, "expected a size such as 512m or 1gb, found '\(text)'", at: node.location)
            return nil
        }
        return String(digits) + unit
    }

    /// The number of bytes a size stands for, with the binary units the engine reads them in.
    static func bytes(_ size: String) -> Double? {
        let trimmed = size.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let powers: [Character: Double] = ["b": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5]
        let unit = trimmed[digits.endIndex...].trimmingCharacters(in: .whitespaces)
        guard let power = powers[unit.first ?? "b"] else { return nil }
        return value * pow(1024, power)
    }

    /// A list of values. One value alone is a list of one where compose allows either.
    func texts(_ node: ComposeNode, _ path: String, allowingSingle: Bool = true) -> [String]? {
        switch node.value {
        case .sequence(let items):
            var result: [String] = []
            for (index, item) in items.enumerated() {
                guard let text = text(item, "\(path)[\(index)]") else { return nil }
                result.append(text)
            }
            return result
        case .scalar(let text) where allowingSingle:
            return [text]
        default:
            diagnostics.error(path, "expected a list, found \(node.kind)", at: node.location)
            return nil
        }
    }

    /// Names with optional values, written as a mapping (`KEY: value`) or as a list
    /// (`- KEY=value`). A name with nothing after it has no value.
    func pairs(_ node: ComposeNode, _ path: String) -> [(key: String, value: String?)]? {
        switch node.value {
        case .mapping(let entries):
            var result: [(key: String, value: String?)] = []
            for entry in entries {
                if entry.value.isNull {
                    result.append((entry.key, nil))
                } else if let text = text(entry.value, "\(path).\(entry.key)") {
                    result.append((entry.key, text))
                } else {
                    return nil
                }
            }
            return result
        case .sequence(let items):
            var result: [(key: String, value: String?)] = []
            for (index, item) in items.enumerated() {
                guard let text = text(item, "\(path)[\(index)]") else { return nil }
                if let equals = text.firstIndex(of: "=") {
                    result.append((String(text[..<equals]), String(text[text.index(after: equals)...])))
                } else {
                    result.append((text, nil))
                }
            }
            return result
        default:
            diagnostics.error(path, "expected a mapping or a list of KEY=value, found \(node.kind)", at: node.location)
            return nil
        }
    }

    /// `pairs` where a name without a value means an empty one: labels, sysctls.
    func dictionary(_ node: ComposeNode, _ path: String) -> [String: String]? {
        guard let pairs = pairs(node, path) else { return nil }
        return Dictionary(pairs.map { ($0.key, $0.value ?? "") }) { _, later in later }
    }

    /// A command: a list of arguments, or one string split the way a shell would.
    func command(_ node: ComposeNode, _ path: String) -> [String]? {
        switch node.value {
        case .scalar(let text):
            do {
                return try ShellWords.split(text)
            } catch {
                diagnostics.error(path, "\(error)", at: node.location)
                return nil
            }
        case .sequence:
            return texts(node, path)
        default:
            diagnostics.error(path, "expected a command as a string or a list, found \(node.kind)", at: node.location)
            return nil
        }
    }
}
