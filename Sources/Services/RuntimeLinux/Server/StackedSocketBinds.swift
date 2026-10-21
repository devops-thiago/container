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

import ContainerResource
import Foundation
import SystemPackage

/// Binds of one host socket that land on one file in the container.
///
/// Dev Containers' docker-outside-of-docker feature makes `/var/run/docker.sock` in the image a
/// symbolic link to `/var/run/docker-host.sock`, and a dev container's Compose file and the
/// feature bind the host's Docker socket at both. Docker mounts the socket twice on that one
/// file. The guest cannot: once a socket is on the file, the second mount finds a socket where
/// it opens its target and fails, and the container does not start. Both binds would put the
/// same socket there, so the first is kept and the rest are left out.
enum StackedSocketBinds {
    /// The indices of the binds in `mounts` to leave out: a socket bind (one of `sockets`)
    /// whose host socket an earlier socket bind already puts on the same file. `file` names
    /// the file a destination is in the image, following its symbolic links, or nil when there
    /// is none yet.
    static func redundant<File: Hashable>(in mounts: [Filesystem], sockets: Set<Int>, file: (String) -> File?) -> Set<Int> {
        var bound: [File: String] = [:]
        var redundant: Set<Int> = []
        for (index, mount) in mounts.enumerated() where sockets.contains(index) {
            guard let target = file(mount.destination) else { continue }
            if let source = bound[target] {
                if source == mount.source { redundant.insert(index) }
                continue
            }
            bound[target] = mount.source
        }
        return redundant
    }

    /// `mounts` without the binds ``redundant(in:sockets:file:)`` finds, reading the files
    /// of the root filesystem image at `rootfs` lazily. Only read when one host socket is bound
    /// more than once, and then on a thread of its own, never one of Swift's cooperative pool.
    static func removing(from mounts: [Filesystem], rootfs: String, isSocket: (Filesystem) -> Bool) async -> [Filesystem] {
        let sockets = Set(mounts.indices.filter { isSocket(mounts[$0]) })
        let sources = sockets.map { mounts[$0].source }
        guard Set(sources).count < sources.count else { return mounts }
        let drop: Set<Int> = await withCheckedContinuation { continuation in
            reading.async {
                guard let files = try? RootfsFiles(image: rootfs) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: redundant(in: mounts, sockets: sockets) { try? files.file($0) })
            }
        }
        return mounts.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Where the image is read: blocking file reads stay off the cooperative pool.
    private static let reading = DispatchQueue(label: "com.apple.container.runtime.stacked-socket-binds")
}
