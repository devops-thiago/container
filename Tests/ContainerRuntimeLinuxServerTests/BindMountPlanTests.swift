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
import Testing

@testable import ContainerRuntimeLinuxServer

struct BindMountPlanTests {
    /// A folder holding `conf` and `extra`, and a sibling folder `other` holding `note`.
    private final class Project {
        let root: URL
        let folder: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("bind-plan-\(UUID().uuidString)")
            folder = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
            for name in ["project/conf", "project/extra", "other/note"] {
                try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }

        func path(_ name: String) -> String { root.appendingPathComponent(name).path }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func tag(of folder: String) throws -> String {
        try Containerization.Mount.share(source: folder, destination: "/").tagHash
    }

    private static func isShare(_ mount: Containerization.Mount) -> Bool {
        if case .virtiofs = mount.runtimeOptions { return true }
        return false
    }

    private static func isGuestBind(_ mount: Containerization.Mount) -> Bool {
        if case .any = mount.runtimeOptions { return mount.type == "none" }
        return false
    }

    @Test
    func aLoneFileIsLeftForContainerizationToShareThroughItsFolder() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.path("project/conf"), destination: "/etc/app.conf", options: ["ro"])
        ])
        #expect(mounts.count == 1)
        #expect(Self.isShare(mounts[0]))
        #expect(mounts[0].source == project.path("project/conf"))
        #expect(mounts[0].destination == "/etc/app.conf")
        #expect(mounts[0].options == ["ro"])
    }

    @Test
    func foldersTmpfsAndMissingSourcesPassThrough() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.folder.path, destination: "/app", options: []),
            .tmpfs(destination: "/run/cache", options: []),
            .virtiofs(source: project.path("missing"), destination: "/missing", options: []),
        ])
        #expect(mounts.count == 3)
        #expect(Self.isShare(mounts[0]) && mounts[0].source == project.folder.path)
        #expect(mounts[1].type == "tmpfs")
        #expect(Self.isShare(mounts[2]) && mounts[2].source == project.path("missing"))
    }

    @Test
    func aFileFromAMountedFolderIsBoundFromThatFoldersShare() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.folder.path, destination: "/app", options: []),
            .virtiofs(source: project.path("project/conf"), destination: "/etc/app.conf", options: ["ro"]),
        ])
        let tag = try Self.tag(of: project.folder.path)
        #expect(Self.isShare(mounts[0]) && mounts[0].destination == "/app")
        #expect(Self.isGuestBind(mounts[1]))
        #expect(mounts[1].source == "/run/virtiofs/\(tag)/conf")
        #expect(mounts[1].destination == "/etc/app.conf")
        #expect(mounts[1].options == ["bind", "ro"])
    }

    @Test
    func theFolderMayComeAfterTheFile() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.path("project/conf"), destination: "/etc/app.conf", options: []),
            .virtiofs(source: project.folder.path, destination: "/app", options: ["ro"]),
        ])
        #expect(Self.isGuestBind(mounts[0]))
        #expect(mounts[0].source == "/run/virtiofs/\(try Self.tag(of: project.folder.path))/conf")
        #expect(mounts[0].options == ["bind"])
        #expect(Self.isShare(mounts[1]))
    }

    @Test
    func twoFilesFromOneFolderShareItOnceThroughAReadWriteCarrier() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.path("project/conf"), destination: "/etc/app.conf", options: ["ro"]),
            .virtiofs(source: project.path("project/extra"), destination: "/var/extra", options: []),
            .virtiofs(source: project.path("other/note"), destination: "/note", options: ["ro"]),
        ])
        let tag = try Self.tag(of: project.folder.path)
        // The read-write file carries the share, so the read-only one cannot make it read-only.
        #expect(Self.isGuestBind(mounts[0]))
        #expect(mounts[0].source == "/run/virtiofs/\(tag)/conf")
        #expect(mounts[0].options == ["bind", "ro"])
        #expect(Self.isShare(mounts[1]))
        #expect(mounts[1].source == project.path("project/extra"))
        // A file in another folder is its own carrier.
        #expect(Self.isShare(mounts[2]))
        #expect(mounts[2].source == project.path("other/note"))
    }

    @Test
    func allReadOnlyFilesKeepTheFirstAsCarrier() throws {
        let project = try Project()
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.path("project/conf"), destination: "/a", options: ["ro"]),
            .virtiofs(source: project.path("project/extra"), destination: "/b", options: ["ro"]),
        ])
        #expect(Self.isShare(mounts[0]))
        #expect(Self.isGuestBind(mounts[1]))
        #expect(mounts[1].source == "/run/virtiofs/\(try Self.tag(of: project.folder.path))/extra")
        #expect(mounts[1].options == ["bind", "ro"])
    }

    @Test
    func aSymlinkedFileIsBoundByItsTargetsNameFromItsTargetsFolder() throws {
        let project = try Project()
        let link = project.path("other/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project.path("project/conf"))
        let mounts = try BindMountPlan.mounts(for: [
            .virtiofs(source: project.folder.path, destination: "/app", options: []),
            .virtiofs(source: link, destination: "/etc/app.conf", options: []),
        ])
        #expect(Self.isGuestBind(mounts[1]))
        #expect(mounts[1].source == "/run/virtiofs/\(try Self.tag(of: project.folder.path))/conf")
    }

    @Test
    func theGrantForAFileIsItsFolder() throws {
        let project = try Project()
        let link = project.path("other/link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project.path("project/conf"))
        let resolvedFolder = project.folder.resolvingSymlinksInPath().path

        #expect(Filesystem.virtiofs(source: project.folder.path, destination: "/app", options: []).sharedFolder == project.folder.path)
        #expect(Filesystem.virtiofs(source: project.path("project/conf"), destination: "/a", options: []).sharedFolder == resolvedFolder)
        #expect(Filesystem.virtiofs(source: link, destination: "/a", options: []).sharedFolder == resolvedFolder)
        #expect(Filesystem.virtiofs(source: project.path("missing"), destination: "/a", options: []).sharedFolder == project.path("missing"))
        #expect(Filesystem.tmpfs(destination: "/t", options: []).sharedFolder == "tmpfs")
    }
}
