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

import ArgumentParser

extension Application {
    /// `container container ls`, for a command line typed with the noun: a person coming from
    /// a CLI that groups these verbs under `container` gets the same commands either way.
    /// Hidden from help, where every verb is already listed once.
    public struct ContainerNoun: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "container",
            abstract: "Manage containers",
            shouldDisplay: false,
            subcommands: Application.containerVerbs)
    }

    /// The container verbs, shared by the root command and its `container` noun so the two
    /// lists cannot drift.
    static let containerVerbs: [any ParsableCommand.Type] = [
        ContainerClean.self,
        ContainerCopy.self,
        ContainerCreate.self,
        ContainerDelete.self,
        ContainerExec.self,
        ContainerExport.self,
        ContainerInspect.self,
        ContainerKill.self,
        ContainerList.self,
        ContainerLogs.self,
        ContainerRestart.self,
        ContainerRun.self,
        ContainerStart.self,
        ContainerStats.self,
        ContainerStop.self,
        ContainerPrune.self,
    ]
}
