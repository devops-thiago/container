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
import ContainerizationOCI
import Foundation

extension Application {
    public struct ImagePrune: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove unused or all images")

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup
        var confirmation: PruneConfirmation

        @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
        var all: Bool = false

        public func run() async throws {
            let allImages = try await ClientImage.list()
            let initImage = try await ClientHealthCheck.loadContainerSystemConfig().vminit.image

            var imagesInUse = Set<String>()
            if all {
                // Find all images not used by any container
                for container in try await ContainerClient().list() {
                    imagesInUse.insert(container.configuration.image.reference)
                }
            }
            let references = Self.referencesToPrune(allImages.map(\.reference), all: all, inUse: imagesInUse, initImage: initImage)
            let imagesToPrune = allImages.filter { references.contains($0.reference) }

            var prunedImages = [String]()

            for image in imagesToPrune {
                do {
                    try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                    prunedImages.append(image.reference)
                } catch {
                    log.error(
                        "failed to prune image",
                        metadata: [
                            "ref": "\(image.reference)",
                            "error": "\(error)",
                        ])
                }
            }

            let (deletedDigests, size) = try await ClientImage.cleanUpOrphanedBlobs()

            for image in imagesToPrune {
                print("untagged \(image.reference)")
            }
            for digest in deletedDigests {
                print("deleted \(digest)")
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let freed = formatter.string(fromByteCount: Int64(size))
            log.info("Reclaimed \(freed) in disk space")
        }

        /// The references a prune removes: the ones with no tag, or with `all` every one no
        /// container uses. Never the init image this engine is configured to start
        /// containers with: the engine holds it by digest, so it has no tag and no container
        /// names it, and a prune that took it made the next start download it again, or
        /// fail with no network. The init image of another engine version is not kept.
        static func referencesToPrune(_ references: [String], all: Bool, inUse: Set<String>, initImage: String) -> Set<String> {
            Set(
                references.filter { reference in
                    guard reference != initImage else { return false }
                    return all ? !inUse.contains(reference) : !hasTag(reference)
                })
        }

        private static func hasTag(_ reference: String) -> Bool {
            do {
                let ref = try ContainerizationOCI.Reference.parse(reference)
                return ref.tag != nil && !ref.tag!.isEmpty
            } catch {
                return false
            }
        }
    }
}
