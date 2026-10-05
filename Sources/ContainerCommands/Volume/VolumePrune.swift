//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerAPIClient
import ContainerResource
import Foundation

extension Application.VolumeCommand {
    public struct VolumePrune: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove anonymous volumes with no container references")

        @Flag(name: .shortAndLong, help: "Remove named volumes with no container references too")
        var all = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup
        var confirmation: PruneConfirmation

        public func run() async throws {
            let allVolumes = try await ClientVolume.list()

            // Find all volumes not used by any container
            let client = ContainerClient()
            let containers = try await client.list()
            var volumesInUse = Set<String>()
            for container in containers {
                for mount in container.configuration.mounts {
                    if mount.isVolume, let volumeName = mount.volumeName {
                        volumesInUse.insert(volumeName)
                    }
                }
            }

            let (volumesToPrune, kept) = Self.selection(from: allVolumes, inUse: volumesInUse, all: all)

            var prunedVolumes = [String]()
            var totalSize: UInt64 = 0

            for volume in volumesToPrune {
                do {
                    let actualSize = try await ClientVolume.volumeDiskUsage(name: volume.name)
                    totalSize += actualSize
                    try await ClientVolume.delete(name: volume.name)
                    prunedVolumes.append(volume.name)
                } catch {
                    log.error(
                        "failed to prune volume",
                        metadata: [
                            "id": "\(volume.name)",
                            "error": "\(error)",
                        ])
                }
            }

            for name in prunedVolumes {
                print(name)
            }

            let formatter = ByteCountFormatter()
            let freed = formatter.string(fromByteCount: Int64(totalSize))
            log.info("Reclaimed \(freed) in disk space")
            if kept > 0 {
                log.info("Kept \(kept) named volume(s) with no container references; --all removes them too")
            }
        }

        /// What a prune removes: the volumes no container refers to, and of those the
        /// anonymous ones unless `all`. A named volume is one somebody chose to keep data in,
        /// and it has no container whenever its containers are removed and made again, as
        /// `compose down` leaves it. `docker volume prune` draws the same line.
        ///
        /// - Returns: the volumes to remove, and how many unreferenced named ones were kept.
        static func selection(
            from volumes: [VolumeConfiguration], inUse: Set<String>, all: Bool
        ) -> (prune: [VolumeConfiguration], kept: Int) {
            let unreferenced = volumes.filter { !inUse.contains($0.name) }
            guard !all else { return (unreferenced, 0) }
            let anonymous = unreferenced.filter(\.isAnonymous)
            return (anonymous, unreferenced.count - anonymous.count)
        }
    }
}
