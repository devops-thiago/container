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

import ContainerizationExtras
import Foundation
import SystemPackage

/// The IPv4 subnet a network was last given, kept beside the network's record.
///
/// A network made without `--subnet` takes whichever subnet is free when its helper starts.
/// With two such networks the one started first gets the first subnet, so the order they are
/// restored in at engine start decided which network got which, and that order is not the
/// order they were made in. A network whose subnet moves takes its containers' addresses
/// with it, and whatever was configured against those addresses, a Kubernetes worker's
/// control-plane endpoint for one, is left pointing at nothing.
///
/// So the subnet a network gets is written down, and asked for again at the next start. It
/// is kept apart from the record's own `ipv4Subnet`, which stays what the user asked for.
enum AssignedSubnet {
    static let filename = "assigned-ipv4-subnet"

    /// The subnet recorded in a network's directory, or nil when none was, or it cannot be read.
    static func read(in directory: FilePath) -> CIDRv4? {
        guard let text = try? String(contentsOfFile: directory.appending(filename).string, encoding: .utf8) else { return nil }
        return try? CIDRv4(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func write(_ subnet: CIDRv4, in directory: FilePath) throws {
        try subnet.description.write(toFile: directory.appending(filename).string, atomically: true, encoding: .utf8)
    }

    /// The recorded subnet to ask for when starting a network the user gave none, or nil to
    /// let the helper choose: nothing was recorded, or a running network has taken it since.
    static func toAskFor(recorded: CIDRv4?, running: [CIDRv4]) -> CIDRv4? {
        guard let recorded else { return nil }
        let taken = running.contains {
            $0.contains(recorded.lower) || $0.contains(recorded.upper) || recorded.contains($0.lower) || recorded.contains($0.upper)
        }
        return taken ? nil : recorded
    }

    /// A saved network, as far as the order to restore it in goes.
    struct Saved: Equatable {
        let id: String
        let creationDate: Date
        /// The network names its subnet: the user gave one, or one was recorded.
        let hasSubnet: Bool
    }

    /// The order to start saved networks in.
    ///
    /// The ones that name their subnet go first, so that none of the others is handed a
    /// subnet one of them is about to ask for. The others, records an earlier engine left
    /// with nothing recorded, go in the order they were made, which is the order they first
    /// got their subnets in: the built-in network before any other, since it always was the
    /// first and its record's date is rewritten at every engine start, then by creation date.
    static func restoreOrder(_ saved: [Saved], builtin: String) -> [String] {
        saved.sorted { a, b in
            if a.hasSubnet != b.hasSubnet { return a.hasSubnet }
            if (a.id == builtin) != (b.id == builtin) { return a.id == builtin }
            if a.creationDate != b.creationDate { return a.creationDate < b.creationDate }
            return a.id < b.id
        }.map(\.id)
    }
}
