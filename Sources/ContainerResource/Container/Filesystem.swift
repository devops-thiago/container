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
import SystemPackage

/// Options to pass to a mount call.
public typealias MountOptions = [String]

extension MountOptions {
    /// Returns true if the Filesystem should be consumed as read-only.
    public var readonly: Bool {
        self.contains("ro")
    }
}

/// A host filesystem that will be attached to the sandbox for use.
///
/// A filesystem will be mounted automatically when starting the sandbox
/// or container.
public struct Filesystem: Sendable, Codable {
    /// Type of caching to perform at the host level.
    public enum CacheMode: Sendable, Codable {
        case on
        case off
        case auto
    }

    /// Sync mode to perform at the host level.
    public enum SyncMode: Sendable, Codable {
        case full
        case fsync
        case nosync
    }

    /// The type of filesystem attachment for the sandbox.
    public enum FSType: Sendable, Codable, Equatable {
        package enum VirtiofsType: String, Sendable, Codable, Equatable {
            // This is a virtiofs share for the rootfs of a sandbox.
            case rootfs
            // Data share. This is what all virtiofs shares for anything besides
            // the rootfs for a sandbox will be.
            case data
        }

        case block(format: String, cache: CacheMode, sync: SyncMode)
        case volume(name: String, format: String, cache: CacheMode, sync: SyncMode)
        case virtiofs
        case tmpfs
    }

    /// Type of the filesystem.
    public var type: FSType
    /// Source of the filesystem.
    public var source: String
    /// Destination where the filesystem should be mounted.
    public var destination: String
    /// Mount options applied when mounting the filesystem.
    public var options: MountOptions

    public init() {
        self.type = .tmpfs
        self.source = ""
        self.destination = ""
        self.options = []
    }

    public init(type: FSType, source: String, destination: String, options: MountOptions) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
    }

    // Defaulting to CachedMode = .on (i.e., cached mode) to fix Linux FS issue when using Virtualization
    // * https://github.com/apple/container/issues/614
    // * https://github.com/utmapp/UTM/pull/5919

    /// A block based filesystem.
    public static func block(
        format: String, source: String, destination: String, options: MountOptions, cache: CacheMode = .on,
        sync: SyncMode = .fsync
    ) -> Filesystem {
        .init(
            type: .block(format: format, cache: cache, sync: sync),
            source: absoluteFilePath(for: source).string,
            destination: destination,
            options: options
        )
    }

    /// A named volume filesystem.
    public static func volume(
        name: String, format: String, source: String, destination: String, options: MountOptions,
        cache: CacheMode = .on, sync: SyncMode = .fsync
    ) -> Filesystem {
        .init(
            type: .volume(name: name, format: format, cache: cache, sync: sync),
            source: absoluteFilePath(for: source).string,
            destination: destination,
            options: options
        )
    }

    /// A vritiofs backed filesystem providing a directory.
    public static func virtiofs(source: String, destination: String, options: MountOptions) -> Filesystem {
        .init(
            type: .virtiofs,
            source: absoluteFilePath(for: source).string,
            destination: destination,
            options: options
        )
    }

    public static func tmpfs(destination: String, options: MountOptions) -> Filesystem {
        .init(
            type: .tmpfs,
            source: "tmpfs",
            destination: destination,
            options: options
        )
    }

    /// Returns true if the Filesystem is backed by a block device.
    public var isBlock: Bool {
        switch type {
        case .block(_, _, _): true
        case .volume(_, _, _, _): true
        default: false
        }
    }

    /// Returns true if the Filesystem is a named volume.
    public var isVolume: Bool {
        switch type {
        case .volume(_, _, _, _): true
        default: false
        }
    }

    /// Returns the volume name if this is a volume filesystem, nil otherwise.
    public var volumeName: String? {
        switch type {
        case .volume(let name, _, _, _): name
        default: nil
        }
    }

    /// Returns true if the Filesystem is backed by a in-memory mount type.
    public var isTmpfs: Bool {
        switch type {
        case .tmpfs: true
        default: false
        }
    }

    /// Returns true if the Filesystem is backed by virtioFS.
    public var isVirtiofs: Bool {
        switch type {
        case .virtiofs: true
        default: false
        }
    }

    /// The host folder a virtiofs mount shares into the VM, which is the folder a sandboxed
    /// engine needs a grant for. That is the source itself, except for a regular file: virtiofs
    /// shares only folders, so a file is bound from a share of the folder that holds it, found
    /// after symbolic links are resolved, the way the runtime finds it.
    public var sharedFolder: String {
        guard isVirtiofs else { return source }
        let resolved = URL(fileURLWithPath: source).resolvingSymlinksInPath()
        var info = stat()
        guard stat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return source
        }
        return resolved.deletingLastPathComponent().path
    }

    /// Clone the Filesystem to the provided path.
    ///
    /// This uses `clonefile` to provide a copy-on-write copy of the Filesystem.
    public func clone(to: String) throws -> Self {
        let fm = FileManager.default
        let src = self.source
        try fm.copyItem(atPath: src, toPath: to)
        return .init(type: self.type, source: to, destination: self.destination, options: self.options)
    }
}

private func absoluteFilePath(for source: String) -> FilePath {
    let path = FilePath(source)
    guard path.isRelative else { return path.lexicallyNormalized() }
    return FilePath(FileManager.default.currentDirectoryPath)
        .pushing(path)
        .lexicallyNormalized()
}
