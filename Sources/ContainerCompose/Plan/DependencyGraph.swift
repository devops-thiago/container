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

/// Which services wait for which. An edge runs from a service to one it depends on.
struct DependencyGraph {
    /// Every service, with the services it depends on.
    let dependencies: [String: [String]]

    /// The services in start order: each one after everything it depends on, and where
    /// several could go next, by name, so that the order does not change from run to run.
    func startOrder() throws -> [String] {
        var remaining = dependencies.mapValues { Set($0.filter { dependencies[$0] != nil }) }
        var order: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.value.isEmpty }.keys.sorted()
            guard !ready.isEmpty else {
                throw ComposeError("services depend on each other in a circle: \(cycle(in: remaining).joined(separator: " → "))")
            }
            for service in ready {
                remaining.removeValue(forKey: service)
                order.append(service)
            }
            for service in remaining.keys {
                remaining[service]?.subtract(ready)
            }
        }
        return order
    }

    /// `roots` and everything they depend on, directly or through another service.
    func closure(of roots: [String]) -> Set<String> {
        var seen = Set<String>()
        var pending = roots
        while let service = pending.popLast() {
            guard seen.insert(service).inserted else { continue }
            pending.append(contentsOf: dependencies[service] ?? [])
        }
        return seen
    }

    /// One circle among services that all still wait for another: followed from the
    /// first by name until a service comes round again.
    private func cycle(in waiting: [String: Set<String>]) -> [String] {
        guard var current = waiting.keys.sorted().first else { return [] }
        var path: [String] = []
        while !path.contains(current) {
            path.append(current)
            guard let next = waiting[current]?.sorted().first(where: { waiting[$0] != nil }) else { break }
            current = next
        }
        guard let start = path.firstIndex(of: current) else { return path }
        return Array(path[start...]) + [current]
    }
}
