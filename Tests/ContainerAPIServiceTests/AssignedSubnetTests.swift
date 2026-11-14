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
import Testing

@testable import ContainerAPIService

/// A network made without a subnet keeps the one it was first given across engine starts.
struct AssignedSubnetTests {
    private func saved(_ id: String, made: TimeInterval, subnet: Bool = false) -> AssignedSubnet.Saved {
        .init(id: id, creationDate: Date(timeIntervalSince1970: made), hasSubnet: subnet)
    }

    @Test func recordedSubnetIsReadBack() throws {
        let directory = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("subnet-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        #expect(AssignedSubnet.read(in: directory) == nil)
        try AssignedSubnet.write(try CIDRv4("192.168.65.0/24"), in: directory)
        #expect(AssignedSubnet.read(in: directory) == (try CIDRv4("192.168.65.0/24")))
        try AssignedSubnet.write(try CIDRv4("192.168.66.0/24"), in: directory)
        #expect(AssignedSubnet.read(in: directory) == (try CIDRv4("192.168.66.0/24")))
    }

    @Test func unreadableRecordIsNoRecord() throws {
        let directory = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("subnet-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        try "not a subnet".write(toFile: directory.appending(AssignedSubnet.filename).string, atomically: true, encoding: .utf8)
        #expect(AssignedSubnet.read(in: directory) == nil)
    }

    @Test func recordedSubnetIsAskedForWhileItIsFree() throws {
        let recorded = try CIDRv4("192.168.65.0/24")
        #expect(AssignedSubnet.toAskFor(recorded: recorded, running: []) == recorded)
        #expect(AssignedSubnet.toAskFor(recorded: recorded, running: [try CIDRv4("192.168.64.0/24")]) == recorded)
        #expect(AssignedSubnet.toAskFor(recorded: nil, running: []) == nil)
    }

    /// Asking for a subnet a running network holds would fail the start; the helper chooses.
    @Test func recordedSubnetARunningNetworkHoldsIsNotAskedFor() throws {
        let recorded = try CIDRv4("192.168.65.0/24")
        #expect(AssignedSubnet.toAskFor(recorded: recorded, running: [try CIDRv4("192.168.65.0/24")]) == nil)
        #expect(AssignedSubnet.toAskFor(recorded: recorded, running: [try CIDRv4("192.168.64.0/23")]) == nil)
        #expect(AssignedSubnet.toAskFor(recorded: recorded, running: [try CIDRv4("192.168.65.128/25")]) == nil)
    }

    /// Networks that name their subnet start first, so none of the rest is handed a subnet
    /// one of them is about to ask for.
    @Test func networksWithASubnetAreRestoredFirst() {
        let order = AssignedSubnet.restoreOrder(
            [saved("default", made: 300), saved("a", made: 100), saved("b", made: 200, subnet: true)], builtin: "default")
        #expect(order == ["b", "default", "a"])
    }

    /// Records an earlier engine left carry no subnet. They go in the order they first got
    /// one: the built-in network first, whose date is rewritten at every start and so says
    /// nothing, then the rest by creation.
    @Test func recordsWithoutASubnetAreRestoredInTheOrderTheyWereMade() {
        let order = AssignedSubnet.restoreOrder(
            [saved("zeta", made: 100), saved("default", made: 900), saved("alpha", made: 200)], builtin: "default")
        #expect(order == ["default", "zeta", "alpha"])
    }

    @Test func networksMadeAtTheSameInstantAreOrderedByName() {
        let order = AssignedSubnet.restoreOrder([saved("b", made: 100), saved("a", made: 100)], builtin: "default")
        #expect(order == ["a", "b"])
    }
}
