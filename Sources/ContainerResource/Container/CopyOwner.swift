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

import Darwin
import Foundation

/// Who owns a file a copy writes into a container.
///
/// dockerd gives each file it unpacks the owner its archive names (the ids the Docker CLI read
/// from the source on the host), and with `copyUIDGID` (`docker cp -a`) the container's user
/// instead. A copy is staged on the Mac before it goes in, and the staged files belong to
/// whoever staged them, so a staged file keeps the owner its archive named in an extended
/// attribute (`record(_:at:)`), and the copy into the container takes it from there.
public struct CopyOwner: Equatable, Sendable, CustomStringConvertible {
    public let uid: UInt32
    public let gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }

    public var description: String { "\(uid):\(gid)" }

    /// The extended attribute a staged file keeps its archive's owner in, as `uid:gid`.
    public static let attribute = "dev.siliconship.copy-owner"

    /// Notes `owner` on the staged file at `path`, not following a link there.
    public static func record(_ owner: CopyOwner, at path: String) throws {
        let value = Array(owner.description.utf8)
        guard setxattr(path, attribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The owner noted on the file at `path`, or nil when there is none: a file that was not
    /// staged from an archive is owned as the host has it.
    public static func recorded(at path: String) -> CopyOwner? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = getxattr(path, attribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard count > 0, let text = String(bytes: buffer.prefix(count), encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let uid = UInt32(parts[0]), let gid = UInt32(parts[1]) else { return nil }
        return CopyOwner(uid: uid, gid: gid)
    }
}
