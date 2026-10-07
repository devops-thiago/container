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

import CYaml
import Foundation

/// Limits apply to the expanded document, including extension fields. Libyaml's event
/// reader checks these before Yams recursively builds nodes or resolves YAML aliases.
/// Ordinary anchors and merge keys retain their YAML semantics.
enum ComposeInput {
    static let maximumBytes = 1_048_576
    private static let maximumNodes = 100_000
    private static let maximumDepth = 64
    static let maximumExpandedBytes = 8 * maximumBytes

    private struct Cost {
        var nodes = 1
        var bytes = 0
        var depth = 1
        var anchor: String?

        mutating func append(_ child: Cost) {
            nodes += child.nodes
            bytes += child.bytes
            depth = max(depth, child.depth + 1)
        }
    }

    static func read(_ path: String) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw ComposeError("\(path) exceeds the 1 MiB compose input limit") }
        guard let text = String(data: data, encoding: .utf8) else { throw ComposeError("\(path) is not UTF-8 text") }
        return text
    }

    static func validate(_ yaml: String, file: String) throws {
        try Task.checkCancellation()
        guard yaml.utf8.count <= maximumBytes else { throw ComposeError("\(file) exceeds the 1 MiB compose input limit") }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else { throw ComposeError("could not initialize the YAML parser") }
        defer { yaml_parser_delete(&parser) }
        let bytes = Array(yaml.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            yaml_parser_set_input_string(&parser, buffer.baseAddress, buffer.count)
            var stack: [Cost] = []
            var anchors: [String: Cost] = [:]
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else {
                    let message = parser.problem.map { String(cString: $0) } ?? "parse failed"
                    throw ComposeError("not valid YAML: \(message)", at: SourceLocation(file: file, line: parser.problem_mark.line + 1, column: parser.problem_mark.column + 1))
                }
                defer { yaml_event_delete(&event) }
                let location = SourceLocation(file: file, line: event.start_mark.line + 1, column: event.start_mark.column + 1)
                var completed: Cost?
                switch event.type {
                case YAML_STREAM_END_EVENT:
                    return
                case YAML_DOCUMENT_START_EVENT:
                    anchors.removeAll()
                case YAML_MAPPING_START_EVENT, YAML_SEQUENCE_START_EVENT:
                    let pointer = event.type == YAML_MAPPING_START_EVENT ? event.data.mapping_start.anchor : event.data.sequence_start.anchor
                    let anchor = pointer.map { String(cString: $0) }
                    // A new anchor shadows an older one immediately; referring to an open
                    // collection cannot be represented as a finite Compose document.
                    if let anchor { anchors.removeValue(forKey: anchor) }
                    stack.append(Cost(anchor: anchor))
                    guard stack.count <= maximumDepth else { throw ComposeError("YAML nesting exceeds 64 levels", at: location) }
                case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT:
                    completed = stack.removeLast()
                case YAML_SCALAR_EVENT:
                    completed = Cost(bytes: event.data.scalar.length, anchor: event.data.scalar.anchor.map { String(cString: $0) })
                case YAML_ALIAS_EVENT:
                    let name = String(cString: event.data.alias.anchor)
                    guard let cost = anchors[name] else { throw ComposeError("not valid YAML: unknown or recursive alias '\(name)'", at: location) }
                    completed = Cost(nodes: cost.nodes, bytes: cost.bytes, depth: cost.depth)
                default:
                    break
                }
                if let cost = completed {
                    guard cost.depth + stack.count <= maximumDepth else { throw ComposeError("YAML nesting exceeds 64 levels", at: location) }
                    if let anchor = cost.anchor { anchors[anchor] = cost }
                    if !stack.isEmpty {
                        stack[stack.count - 1].append(cost)
                    }
                    let total = stack.last ?? cost
                    guard total.nodes <= maximumNodes, total.bytes <= maximumExpandedBytes else {
                        throw ComposeError("expanded YAML exceeds the compose input budget (100000 nodes or 8 MiB of scalar text)", at: location)
                    }
                }
            }
        }
    }
}
