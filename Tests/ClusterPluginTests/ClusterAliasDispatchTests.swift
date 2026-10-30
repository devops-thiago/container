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
import Testing

@testable import ContainerCluster
@testable import ContainerPlugin

func dispatchedClusterArguments(_ invokedAs: String, _ command: String, extra: [String] = []) -> [String] {
    let plugin = Plugin(
        binaryURL: URL(fileURLWithPath: "/fixture/plugins/cluster/bin/cluster"),
        config: PluginConfig(abstract: "cluster", author: "Apple", servicesConfig: nil, aliases: ["k8s"]))
    return plugin.executionArguments(args: [invokedAs, command] + extra)
}

@Suite("cluster alias dispatch and parsing")
struct ClusterAliasDispatchTests {
    enum Command: String, CaseIterable, Sendable {
        case create, start, stop, delete
        case writeConfig = "write-config"
        case loadImage = "load-image"

        func parseName(_ arguments: [String]) throws -> String {
            switch self {
            case .create: try ClusterCreate.parse(arguments).name
            case .start: try ClusterStart.parse(arguments).name
            case .stop: try ClusterStop.parse(arguments).name
            case .delete: try ClusterDelete.parse(arguments).name
            case .writeConfig: try ClusterWriteConfig.parse(arguments).name
            case .loadImage: try ClusterLoadImage.parse(arguments).name
            }
        }
    }

    @Test(arguments: Command.allCases, ["k8s", "cluster"])
    func defaultSelection(command: Command, invokedAs: String) throws {
        let extra = command == .loadImage ? ["example:local"] : []
        let argv = dispatchedClusterArguments(invokedAs, command.rawValue, extra: extra)
        let selected = try ClusterCommandContext.$invokedAs.withValue(URL(fileURLWithPath: argv[0]).lastPathComponent) {
            try command.parseName(Array(argv.dropFirst(2)))
        }
        #expect(selected == (invokedAs == "k8s" ? "k8s-dev" : "cluster-dev"))
        #expect(ClusterHelper.defaultName == "cluster-dev", "the embedded API default remains independent of CLI aliases")
    }

    @Test(arguments: Command.allCases, ["k8s", "cluster"])
    func explicitNameWins(command: Command, invokedAs: String) throws {
        let extra = ["--name", "chosen"] + (command == .loadImage ? ["example:local"] : [])
        let argv = dispatchedClusterArguments(invokedAs, command.rawValue, extra: extra)
        let selected = try ClusterCommandContext.$invokedAs.withValue(URL(fileURLWithPath: argv[0]).lastPathComponent) {
            try command.parseName(Array(argv.dropFirst(2)))
        }
        #expect(selected == "chosen")
    }
}
