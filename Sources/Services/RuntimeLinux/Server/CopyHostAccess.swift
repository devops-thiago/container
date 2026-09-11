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

import ContainerAPIClient
import ContainerizationError
import Foundation

extension RuntimeService {
    /// Resolving the app's plain bookmark extends this process's sandbox. The caller holds
    /// the URL until copying finishes and releases it on success and failure alike.
    static func copyHostAccess(bookmark: Data?, path: String, sandboxed: Bool = ClientHostDirectory.isSandboxed) throws -> URL? {
        guard let bookmark else {
            guard !sandboxed else {
                throw ContainerizationError(.invalidArgument, message: "copy has no host directory permission for \(path)")
            }
            return nil
        }
        var stale = false
        let access = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let root = access.resolvingSymlinksInPath().standardizedFileURL.path
        // Foundation does not resolve an intermediate symlink when the final output does
        // not exist. Resolve the existing ancestor before appending the not-yet-created tail.
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var targetURL = ancestor.resolvingSymlinksInPath()
        for component in tail.reversed() { targetURL.appendPathComponent(component) }
        let target = targetURL.path
        guard target == root || target.hasPrefix(root == "/" ? "/" : root + "/") else {
            access.stopAccessingSecurityScopedResource()
            throw ContainerizationError(.invalidArgument, message: "copy permission does not cover \(path)")
        }
        return access
    }
}
