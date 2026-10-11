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
import Containerization
import Foundation

/// The mounts a container's filesystems become in the VM.
///
/// virtiofs shares folders, not files. Containerization handles a single file itself: its
/// `FileMountContext` shares the folder that holds the file at a private path in the VM,
/// outside the container's root filesystem, and binds only the file into the container, so
/// the rest of that folder is never visible there. Two arrangements it gets wrong are planned
/// here instead, by binding the file from a share that already exists:
///
/// - A file whose folder is also mounted as a directory. Both mounts get the same share tag,
///   and containerization drops every mount with a file's share tag from the container's
///   mounts, so the directory mount would silently not appear. The file is bound from the
///   directory mount's share.
/// - Two files from one folder. Containerization shares that folder once, with the options
///   of the first file, so a read-only first file makes the second one read-only too. One
///   file carries the share, a read-write one when there is one, and the others are bound
///   from it; `ro` on a bind is applied to that bind alone.
///
/// What cannot be planned around: a file mounted read-write from a folder that is also
/// mounted read-only. The VM gets one share of that folder, read-only, so writes to the
/// file fail.
enum BindMountPlan {
    /// Where containerization 0.47.0 mounts each virtiofs share in the VM: under this folder,
    /// in a subfolder named by the share's tag (`Mount.tagHash`). It is containerization's
    /// convention, not an API: `FileMount.swift:180` binds single files from it and
    /// `LinuxContainer.swift:831` and `:936` bind folders from it. A containerization update
    /// that moves it breaks the binds this plan makes, so check those lines when bumping.
    static let guestShareRoot = "/run/virtiofs"

    /// The mounts to hand containerization for `filesystems`, in their order. A file that
    /// carries its folder's share, and anything that is not a file bound from a shared folder,
    /// is converted as is.
    static func mounts(for filesystems: [Filesystem]) throws -> [Containerization.Mount] {
        var mounts = filesystems.map(\.asMount)

        var directoryTags: Set<String> = []
        var filesByTag: [String: [SharedFile]] = [:]
        var tagOrder: [String] = []
        for (index, mount) in mounts.enumerated() {
            guard case .virtiofs = mount.runtimeOptions else { continue }
            var isDirectory: ObjCBool = false
            // A source that does not exist is left for containerization to report.
            guard FileManager.default.fileExists(atPath: mount.source, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                directoryTags.insert(try mount.tagHash)
                continue
            }
            // Resolved as containerization resolves it, so the tag and the name match the
            // share it makes.
            let resolved = URL(fileURLWithPath: mount.source).resolvingSymlinksInPath()
            let folder = resolved.deletingLastPathComponent().path
            let tag = try Containerization.Mount.share(source: folder, destination: "/").tagHash
            if filesByTag[tag] == nil { tagOrder.append(tag) }
            filesByTag[tag, default: []].append(SharedFile(index: index, name: resolved.lastPathComponent))
        }

        for tag in tagOrder {
            guard let files = filesByTag[tag] else { continue }
            let carrier: Int?
            if directoryTags.contains(tag) {
                carrier = nil
            } else {
                carrier = files.first { !mounts[$0.index].options.contains("ro") }?.index ?? files.first?.index
            }
            for file in files where file.index != carrier {
                let mount = mounts[file.index]
                mounts[file.index] = .any(
                    type: "none",
                    source: "\(guestShareRoot)/\(tag)/\(file.name)",
                    destination: mount.destination,
                    options: ["bind"] + mount.options
                )
            }
        }
        return mounts
    }

    private struct SharedFile {
        let index: Int
        let name: String
    }
}
